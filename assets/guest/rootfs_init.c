#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define VIRTIO_NET_MMIO_GPA 0xFE000000UL
#define VIRTIO_BLK_MMIO_GPA 0xFE001000UL
#define GUEST_BLK_RING_GPA  0x000D0000UL
#define GUEST_BLK_RING_SIZE 0x00002000UL
#define GUEST_NET_RING_GPA  0x000D2000UL
#define GUEST_NET_RING_SIZE 0x00004000UL

#define VIRTIO_MMIO_MAGIC_VALUE         0x000
#define VIRTIO_MMIO_VERSION             0x004
#define VIRTIO_MMIO_DEVICE_ID           0x008
#define VIRTIO_MMIO_DEVICE_FEATURES     0x010
#define VIRTIO_MMIO_DEVICE_FEATURES_SEL 0x014
#define VIRTIO_MMIO_DRIVER_FEATURES     0x020
#define VIRTIO_MMIO_DRIVER_FEATURES_SEL 0x024
#define VIRTIO_MMIO_QUEUE_SEL           0x030
#define VIRTIO_MMIO_QUEUE_NUM_MAX       0x034
#define VIRTIO_MMIO_QUEUE_NUM           0x038
#define VIRTIO_MMIO_QUEUE_READY         0x044
#define VIRTIO_MMIO_QUEUE_NOTIFY        0x050
#define VIRTIO_MMIO_INTERRUPT_STATUS    0x060
#define VIRTIO_MMIO_INTERRUPT_ACK       0x064
#define VIRTIO_MMIO_STATUS              0x070
#define VIRTIO_MMIO_QUEUE_DESC_LOW      0x080
#define VIRTIO_MMIO_QUEUE_DESC_HIGH     0x084
#define VIRTIO_MMIO_QUEUE_DRIVER_LOW    0x090
#define VIRTIO_MMIO_QUEUE_DRIVER_HIGH   0x094
#define VIRTIO_MMIO_QUEUE_DEVICE_LOW    0x0A0
#define VIRTIO_MMIO_QUEUE_DEVICE_HIGH   0x0A4
#define VIRTIO_MMIO_CONFIG              0x100

#define VIRTIO_STATUS_ACKNOWLEDGE 1U
#define VIRTIO_STATUS_DRIVER      2U
#define VIRTIO_STATUS_DRIVER_OK   4U
#define VIRTIO_STATUS_FEATURES_OK 8U

#define VIRTQ_DESC_F_NEXT  1U
#define VIRTQ_DESC_F_WRITE 2U

#define VIRTIO_BLK_F_FLUSH (1U << 9)
#define VIRTIO_BLK_T_IN    0U
#define VIRTIO_BLK_T_OUT   1U
#define VIRTIO_BLK_T_FLUSH 4U
#define VIRTIO_BLK_T_FUA   (1U << 4)

struct virtq_desc {
    uint64_t addr;
    uint32_t len;
    uint16_t flags;
    uint16_t next;
} __attribute__((packed));

struct virtq_avail {
    uint16_t flags;
    uint16_t idx;
    uint16_t ring[16];
    uint16_t used_event;
} __attribute__((packed));

struct virtq_used_elem {
    uint32_t id;
    uint32_t len;
} __attribute__((packed));

struct virtq_used {
    uint16_t flags;
    uint16_t idx;
    struct virtq_used_elem ring[16];
    uint16_t avail_event;
} __attribute__((packed));

struct virtio_blk_req_hdr {
    uint32_t type;
    uint32_t reserved;
    uint64_t sector;
} __attribute__((packed));

static inline uint32_t mmio_read32(const volatile uint8_t *base, uint32_t offset) {
    uint32_t val;
    const volatile void *addr = (const volatile void *)(base + offset);
    __asm__ volatile("movl (%1), %0" : "=a"(val) : "r"(addr) : "memory");
    return val;
}

static inline void mmio_write32(volatile uint8_t *base, uint32_t offset, uint32_t val) {
    volatile void *addr = (volatile void *)(base + offset);
    __asm__ volatile("movl %0, (%1)" :: "a"(val), "r"(addr) : "memory");
}

static int g_mem_fd = -1;
static volatile uint8_t *g_net_mmio = NULL;
static volatile uint8_t *g_blk_mmio = NULL;
static uint8_t *g_blk_mem = NULL;
static uint8_t *g_net_mem = NULL;
static uint8_t g_mac[6];
static uint32_t g_vmid = 0;
static uint16_t g_blk_last_used = 0;
static uint16_t g_net_rx_last_used = 0;
static int g_net_initialized = 0;

static int ensure_mappings(void) {
    if (g_mem_fd >= 0) return 0;

    g_mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_mem_fd < 0) {
        printf("guest_err: open /dev/mem failed\n");
        return -1;
    }

    void *net_mmio = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, g_mem_fd, VIRTIO_NET_MMIO_GPA);
    void *blk_mmio = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, g_mem_fd, VIRTIO_BLK_MMIO_GPA);
    void *blk_mem = mmap(NULL, GUEST_BLK_RING_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, g_mem_fd, GUEST_BLK_RING_GPA);
    void *net_mem = mmap(NULL, GUEST_NET_RING_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, g_mem_fd, GUEST_NET_RING_GPA);

    if (net_mmio == MAP_FAILED || blk_mmio == MAP_FAILED || blk_mem == MAP_FAILED || net_mem == MAP_FAILED) {
        printf("guest_err: mmap /dev/mem failed\n");
        return -1;
    }

    g_net_mmio = (volatile uint8_t *)net_mmio;
    g_blk_mmio = (volatile uint8_t *)blk_mmio;
    g_blk_mem = (uint8_t *)blk_mem;
    g_net_mem = (uint8_t *)net_mem;

    uint32_t mac_lo = mmio_read32(g_net_mmio, VIRTIO_MMIO_CONFIG + 0);
    uint32_t mac_hi = mmio_read32(g_net_mmio, VIRTIO_MMIO_CONFIG + 4);
    g_mac[0] = (uint8_t)(mac_lo & 0xFFU);
    g_mac[1] = (uint8_t)((mac_lo >> 8) & 0xFFU);
    g_mac[2] = (uint8_t)((mac_lo >> 16) & 0xFFU);
    g_mac[3] = (uint8_t)((mac_lo >> 24) & 0xFFU);
    g_mac[4] = (uint8_t)(mac_hi & 0xFFU);
    g_mac[5] = (uint8_t)((mac_hi >> 8) & 0xFFU);
    g_vmid = ((uint32_t)g_mac[4] << 8) | (uint32_t)g_mac[5];
    if (g_vmid == 0) g_vmid = 1;

    return 0;
}

static int blk_submit(uint32_t req_type, uint64_t sector, int has_data, uint8_t *out_status) {
    volatile struct virtq_desc *desc = (volatile struct virtq_desc *)(g_blk_mem + 0x000);
    volatile struct virtq_avail *avail = (volatile struct virtq_avail *)(g_blk_mem + 0x100);
    volatile struct virtq_used *used = (volatile struct virtq_used *)(g_blk_mem + 0x200);
    volatile struct virtio_blk_req_hdr *hdr = (volatile struct virtio_blk_req_hdr *)(g_blk_mem + 0x400);
    volatile uint8_t *status_byte = (volatile uint8_t *)(g_blk_mem + 0x420);

    hdr->type = req_type;
    hdr->reserved = 0;
    hdr->sector = sector;
    *status_byte = 0xFFU;

    desc[0].addr = GUEST_BLK_RING_GPA + 0x400UL;
    desc[0].len = sizeof(struct virtio_blk_req_hdr);
    desc[0].flags = VIRTQ_DESC_F_NEXT;
    desc[0].next = 1;

    if (has_data) {
        uint32_t base_op = req_type & ~VIRTIO_BLK_T_FUA;
        desc[1].addr = GUEST_BLK_RING_GPA + 0x1000UL;
        desc[1].len = 512;
        desc[1].flags = VIRTQ_DESC_F_NEXT | (base_op == VIRTIO_BLK_T_IN ? VIRTQ_DESC_F_WRITE : 0U);
        desc[1].next = 2;

        desc[2].addr = GUEST_BLK_RING_GPA + 0x420UL;
        desc[2].len = 1;
        desc[2].flags = VIRTQ_DESC_F_WRITE;
        desc[2].next = 0;
    } else {
        desc[1].addr = GUEST_BLK_RING_GPA + 0x420UL;
        desc[1].len = 1;
        desc[1].flags = VIRTQ_DESC_F_WRITE;
        desc[1].next = 0;
    }

    uint16_t a_idx = avail->idx;
    avail->ring[a_idx % 16U] = 0;
    __asm__ volatile("" ::: "memory");
    avail->idx = (uint16_t)(a_idx + 1U);
    __asm__ volatile("" ::: "memory");

    mmio_write32(g_blk_mmio, VIRTIO_MMIO_QUEUE_NOTIFY, 0);

    for (uint32_t spin = 0; spin < 200000U; spin++) {
        __asm__ volatile("" ::: "memory");
        if (used->idx != g_blk_last_used) {
            g_blk_last_used = used->idx;
            uint32_t irq = mmio_read32(g_blk_mmio, VIRTIO_MMIO_INTERRUPT_STATUS);
            if (irq != 0) mmio_write32(g_blk_mmio, VIRTIO_MMIO_INTERRUPT_ACK, irq);
            *out_status = *status_byte;
            return 0;
        }
        /* Reading InterruptStatus yields the vCPU so Ring-3 storaged can complete the request. */
        (void)mmio_read32(g_blk_mmio, VIRTIO_MMIO_INTERRUPT_STATUS);
    }

    return -1;
}

static void run_blk_test(void) {
    if (ensure_mappings() < 0) return;

    /* Fault all guest ring/data pages into the per-VM EPT before configuring the queue. */
    memset(g_blk_mem, 0, GUEST_BLK_RING_SIZE);
    g_blk_last_used = 0;

    uint32_t magic = mmio_read32(g_blk_mmio, VIRTIO_MMIO_MAGIC_VALUE);
    uint32_t version = mmio_read32(g_blk_mmio, VIRTIO_MMIO_VERSION);
    uint32_t dev_id = mmio_read32(g_blk_mmio, VIRTIO_MMIO_DEVICE_ID);
    uint32_t cap_lo = mmio_read32(g_blk_mmio, VIRTIO_MMIO_CONFIG + 0);
    if (magic != 0x74726976U || version != 2U || dev_id != 2U || cap_lo == 0U) {
        printf("guest_blk: probe failed magic=0x%x ver=%u id=%u cap=%u\n", magic, version, dev_id, cap_lo);
        return;
    }

    mmio_write32(g_blk_mmio, VIRTIO_MMIO_STATUS, 0);
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_STATUS, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER);
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_DEVICE_FEATURES_SEL, 0);
    uint32_t features = mmio_read32(g_blk_mmio, VIRTIO_MMIO_DEVICE_FEATURES);
    if ((features & VIRTIO_BLK_F_FLUSH) == 0) {
        printf("guest_blk: VIRTIO_BLK_F_FLUSH not advertised\n");
        return;
    }
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_DRIVER_FEATURES_SEL, 0);
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_DRIVER_FEATURES, VIRTIO_BLK_F_FLUSH);
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_STATUS,
                 VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK);

    mmio_write32(g_blk_mmio, VIRTIO_MMIO_QUEUE_SEL, 0);
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_QUEUE_NUM, 16);
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_QUEUE_DESC_LOW, (uint32_t)(GUEST_BLK_RING_GPA + 0x000UL));
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_QUEUE_DESC_HIGH, 0);
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_QUEUE_DRIVER_LOW, (uint32_t)(GUEST_BLK_RING_GPA + 0x100UL));
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_QUEUE_DRIVER_HIGH, 0);
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_QUEUE_DEVICE_LOW, (uint32_t)(GUEST_BLK_RING_GPA + 0x200UL));
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_QUEUE_DEVICE_HIGH, 0);
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_QUEUE_READY, 1);
    mmio_write32(g_blk_mmio, VIRTIO_MMIO_STATUS,
                 VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK);

    uint8_t status = 0xFFU;
    uint8_t *sector_buf = g_blk_mem + 0x1000;

    /* 1. Out-of-bounds sector rejection (sector == capacity_sectors) */
    if (blk_submit(VIRTIO_BLK_T_IN, cap_lo, 1, &status) < 0 || status != 1U) {
        printf("guest_blk: oob check failed status=%u\n", status);
        return;
    }
    printf("guest_blk: out-of-bounds sector rejected\n");

    /* 2. Cross-VM extent isolation: read sector 0 before writing our own tag */
    memset(sector_buf, 0, 512);
    if (blk_submit(VIRTIO_BLK_T_IN, 0, 1, &status) < 0 || status != 0U) {
        printf("guest_blk: initial read failed status=%u\n", status);
        return;
    }
    const char *peer_tag = (g_vmid == 1U) ? "CATENARY-VM2-DISK" : "CATENARY-VM1-DISK";
    if (memcmp(sector_buf, peer_tag, strlen(peer_tag)) == 0) {
        printf("guest_blk: isolation violation saw peer tag %s\n", peer_tag);
        return;
    }
    printf("guest_blk: extent isolated\n");

    /* 3. FUA write + explicit flush + readback */
    const char *own_tag = (g_vmid == 1U) ? "CATENARY-VM1-DISK" : "CATENARY-VM2-DISK";
    for (size_t i = 0; i < 512; i++) {
        sector_buf[i] = (uint8_t)((i + g_vmid) & 0xFFU);
    }
    memcpy(sector_buf, own_tag, strlen(own_tag) + 1U);

    if (blk_submit(VIRTIO_BLK_T_OUT | VIRTIO_BLK_T_FUA, 0, 1, &status) < 0 || status != 0U) {
        printf("guest_blk: FUA write failed status=%u\n", status);
        return;
    }
    if (blk_submit(VIRTIO_BLK_T_FLUSH, 0, 0, &status) < 0 || status != 0U) {
        printf("guest_blk: flush failed status=%u\n", status);
        return;
    }

    memset(sector_buf, 0, 512);
    if (blk_submit(VIRTIO_BLK_T_IN, 0, 1, &status) < 0 || status != 0U) {
        printf("guest_blk: readback failed status=%u\n", status);
        return;
    }
    if (memcmp(sector_buf, own_tag, strlen(own_tag) + 1U) != 0 ||
        sector_buf[511] != (uint8_t)((511U + g_vmid) & 0xFFU)) {
        printf("guest_blk: readback mismatch\n");
        return;
    }
    printf("guest_blk: FUA write+flush+readback OK tag=%s\n", own_tag);
}

static int ensure_net_init(void) {
    if (g_net_initialized) return 0;
    if (ensure_mappings() < 0) return -1;

    /* Touch all 4 pages of g_net_mem so they are mapped in the per-VM EPT. */
    memset(g_net_mem, 0, GUEST_NET_RING_SIZE);
    g_net_rx_last_used = 0;

    uint32_t magic = mmio_read32(g_net_mmio, VIRTIO_MMIO_MAGIC_VALUE);
    uint32_t version = mmio_read32(g_net_mmio, VIRTIO_MMIO_VERSION);
    uint32_t dev_id = mmio_read32(g_net_mmio, VIRTIO_MMIO_DEVICE_ID);
    if (magic != 0x74726976U || version != 2U || dev_id != 1U) {
        printf("guest_net: probe failed magic=0x%x ver=%u id=%u\n", magic, version, dev_id);
        return -1;
    }

    mmio_write32(g_net_mmio, VIRTIO_MMIO_STATUS, 0);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_STATUS, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_DEVICE_FEATURES_SEL, 0);
    (void)mmio_read32(g_net_mmio, VIRTIO_MMIO_DEVICE_FEATURES);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_DRIVER_FEATURES_SEL, 0);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_DRIVER_FEATURES, 0);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_STATUS,
                 VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK);

    /* Queue 0: RX (8 buffers of 512 bytes at 0x000D3000..0x000D3FFF) */
    volatile struct virtq_desc *rx_desc = (volatile struct virtq_desc *)(g_net_mem + 0x000);
    volatile struct virtq_avail *rx_avail = (volatile struct virtq_avail *)(g_net_mem + 0x100);
    for (uint16_t i = 0; i < 8U; i++) {
        rx_desc[i].addr = GUEST_NET_RING_GPA + 0x1000UL + ((uint64_t)i * 512UL);
        rx_desc[i].len = 512;
        rx_desc[i].flags = VIRTQ_DESC_F_WRITE;
        rx_desc[i].next = 0;
        rx_avail->ring[i] = i;
    }
    __asm__ volatile("" ::: "memory");
    rx_avail->idx = 8;
    __asm__ volatile("" ::: "memory");

    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_SEL, 0);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_NUM, 8);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_DESC_LOW, (uint32_t)(GUEST_NET_RING_GPA + 0x000UL));
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_DESC_HIGH, 0);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_DRIVER_LOW, (uint32_t)(GUEST_NET_RING_GPA + 0x100UL));
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_DRIVER_HIGH, 0);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_DEVICE_LOW, (uint32_t)(GUEST_NET_RING_GPA + 0x200UL));
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_DEVICE_HIGH, 0);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_READY, 1);

    /* Queue 1: TX (descriptors at +0x400, avail at +0x500, used at +0x600, buffer at +0x2000) */
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_SEL, 1);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_NUM, 8);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_DESC_LOW, (uint32_t)(GUEST_NET_RING_GPA + 0x400UL));
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_DESC_HIGH, 0);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_DRIVER_LOW, (uint32_t)(GUEST_NET_RING_GPA + 0x500UL));
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_DRIVER_HIGH, 0);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_DEVICE_LOW, (uint32_t)(GUEST_NET_RING_GPA + 0x600UL));
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_DEVICE_HIGH, 0);
    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_READY, 1);

    mmio_write32(g_net_mmio, VIRTIO_MMIO_STATUS,
                 VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK);

    g_net_initialized = 1;
    return 0;
}

static void net_tx_frame(const uint8_t *frame, uint32_t len) {
    volatile struct virtq_desc *tx_desc = (volatile struct virtq_desc *)(g_net_mem + 0x400);
    volatile struct virtq_avail *tx_avail = (volatile struct virtq_avail *)(g_net_mem + 0x500);
    uint8_t *tx_buf = g_net_mem + 0x2000;

    memcpy(tx_buf, frame, len);
    tx_desc[0].addr = GUEST_NET_RING_GPA + 0x2000UL;
    tx_desc[0].len = len;
    tx_desc[0].flags = 0;
    tx_desc[0].next = 0;

    uint16_t a_idx = tx_avail->idx;
    tx_avail->ring[a_idx % 8U] = 0;
    __asm__ volatile("" ::: "memory");
    tx_avail->idx = (uint16_t)(a_idx + 1U);
    __asm__ volatile("" ::: "memory");

    mmio_write32(g_net_mmio, VIRTIO_MMIO_QUEUE_NOTIFY, 1);
    /* Give netd an extra scheduling slice if needed. */
    (void)mmio_read32(g_net_mmio, VIRTIO_MMIO_INTERRUPT_STATUS);
}

static void build_udp4_frame(uint8_t *frame, const uint8_t *src_mac, uint8_t src_host, uint8_t dst_host) {
    const char payload[16] = "CATENARY-UDP4-OK";
    memset(frame, 0, 58);
    /* Ethernet header */
    frame[0] = g_mac[0];
    frame[1] = g_mac[1];
    frame[2] = g_mac[2];
    frame[3] = g_mac[3];
    frame[4] = g_mac[4];
    frame[5] = dst_host;
    memcpy(frame + 6, src_mac, 6);
    frame[12] = 0x08;
    frame[13] = 0x00;

    /* IPv4 header (20 bytes) */
    uint8_t *ip = frame + 14;
    ip[0] = 0x45;
    ip[1] = 0x00;
    ip[2] = 0x00;
    ip[3] = 44; /* 20 + 8 + 16 */
    ip[4] = 0x00;
    ip[5] = 0x01;
    ip[6] = 0x40; /* DF */
    ip[7] = 0x00;
    ip[8] = 64;
    ip[9] = 17; /* UDP */
    ip[12] = 10;
    ip[13] = 77;
    ip[14] = 0;
    ip[15] = src_host;
    ip[16] = 10;
    ip[17] = 77;
    ip[18] = 0;
    ip[19] = dst_host;

    /* UDP header (8 bytes) + 16-byte payload */
    uint8_t *udp = ip + 20;
    udp[0] = (uint8_t)(5000U >> 8);
    udp[1] = (uint8_t)(5000U & 0xFFU);
    udp[2] = (uint8_t)(5001U >> 8);
    udp[3] = (uint8_t)(5001U & 0xFFU);
    udp[4] = 0x00;
    udp[5] = 24;
    memcpy(udp + 8, payload, 16);
}

static void run_net_init(void) {
    if (ensure_net_init() < 0) return;
    printf("guest_net: ready mac=%02x:%02x:%02x:%02x:%02x:%02x vmid=%u\n",
           g_mac[0], g_mac[1], g_mac[2], g_mac[3], g_mac[4], g_mac[5], g_vmid);
}

static void run_net_spoof(void) {
    if (ensure_net_init() < 0) return;
    uint8_t self_host = (uint8_t)(g_vmid & 0xFFU);
    uint8_t peer_host = (self_host == 1U) ? 2U : 1U;
    uint8_t frame[64];

    /* 1. Spoofed source MAC */
    uint8_t spoof_mac[6] = {0x02, 0xca, 0x00, 0x00, 0x00, 0x99};
    build_udp4_frame(frame, spoof_mac, self_host, peer_host);
    net_tx_frame(frame, 58);

    /* 2. Legitimate source MAC, unauthorized source IPv4 */
    build_udp4_frame(frame, g_mac, 99U, peer_host);
    net_tx_frame(frame, 58);

    printf("guest_net: spoof probes sent\n");
}

static void run_net_arp(void) {
    if (ensure_net_init() < 0) return;
    uint8_t self_host = (uint8_t)(g_vmid & 0xFFU);
    uint8_t peer_host = (self_host == 1U) ? 2U : 1U;
    uint8_t frame[42];
    memset(frame, 0, sizeof(frame));

    /* Broadcast destination MAC */
    memset(frame, 0xFF, 6);
    memcpy(frame + 6, g_mac, 6);
    frame[12] = 0x08;
    frame[13] = 0x06;

    /* ARP Ethernet/IPv4 request */
    uint8_t *arp = frame + 14;
    arp[0] = 0x00;
    arp[1] = 0x01;
    arp[2] = 0x08;
    arp[3] = 0x00;
    arp[4] = 6;
    arp[5] = 4;
    arp[6] = 0x00;
    arp[7] = 0x01;
    memcpy(arp + 8, g_mac, 6);
    arp[14] = 10;
    arp[15] = 77;
    arp[16] = 0;
    arp[17] = self_host;
    memset(arp + 18, 0, 6);
    arp[24] = 10;
    arp[25] = 77;
    arp[26] = 0;
    arp[27] = peer_host;

    net_tx_frame(frame, sizeof(frame));
    printf("guest_net: arp sent\n");
}

static void run_net_tx_v4(void) {
    if (ensure_net_init() < 0) return;
    uint8_t self_host = (uint8_t)(g_vmid & 0xFFU);
    uint8_t peer_host = (self_host == 1U) ? 2U : 1U;
    uint8_t frame[58];
    build_udp4_frame(frame, g_mac, self_host, peer_host);
    net_tx_frame(frame, sizeof(frame));
    printf("guest_net: udp4 sent\n");
}

static void run_net_tx_v6(void) {
    if (ensure_net_init() < 0) return;
    uint8_t self_host = (uint8_t)(g_vmid & 0xFFU);
    uint8_t peer_host = (self_host == 1U) ? 2U : 1U;
    const char payload[17] = "CATENARY-ICMP6-OK";
    uint8_t frame[79];
    memset(frame, 0, sizeof(frame));

    frame[0] = g_mac[0];
    frame[1] = g_mac[1];
    frame[2] = g_mac[2];
    frame[3] = g_mac[3];
    frame[4] = g_mac[4];
    frame[5] = peer_host;
    memcpy(frame + 6, g_mac, 6);
    frame[12] = 0x86;
    frame[13] = 0xDD;

    /* IPv6 header (40 bytes) */
    uint8_t *ip6 = frame + 14;
    ip6[0] = 0x60;
    ip6[4] = 0x00;
    ip6[5] = 25; /* 8 + 17 */
    ip6[6] = 58; /* ICMPv6 */
    ip6[7] = 64;
    ip6[8] = 0xfd;
    ip6[9] = 0x00;
    ip6[23] = self_host;
    ip6[24] = 0xfd;
    ip6[25] = 0x00;
    ip6[39] = peer_host;

    /* ICMPv6 Echo Request (8 bytes + 17-byte payload) */
    uint8_t *icmp6 = ip6 + 40;
    icmp6[0] = 128; /* Echo Request */
    icmp6[1] = 0;
    icmp6[4] = 0x00;
    icmp6[5] = 0x01;
    icmp6[6] = 0x00;
    icmp6[7] = 0x01;
    memcpy(icmp6 + 8, payload, 17);

    net_tx_frame(frame, sizeof(frame));
    printf("guest_net: icmp6 sent\n");
}

static void run_net_rx(void) {
    if (ensure_net_init() < 0) return;

    volatile struct virtq_avail *rx_avail = (volatile struct virtq_avail *)(g_net_mem + 0x100);
    volatile struct virtq_used *rx_used = (volatile struct virtq_used *)(g_net_mem + 0x200);
    uint32_t received = 0;

    for (uint32_t spin = 0; spin < 40000U; spin++) {
        (void)mmio_read32(g_net_mmio, VIRTIO_MMIO_INTERRUPT_STATUS);
        __asm__ volatile("" ::: "memory");
        while (rx_used->idx != g_net_rx_last_used) {
            uint16_t u_slot = g_net_rx_last_used % 8U;
            uint32_t desc_id = rx_used->ring[u_slot].id & 7U;
            uint32_t frame_len = rx_used->ring[u_slot].len;
            const uint8_t *buf = g_net_mem + 0x1000 + (desc_id * 512U);

            if (frame_len >= 14U) {
                uint16_t eth_type = ((uint16_t)buf[12] << 8) | buf[13];
                if (eth_type == 0x0806U && frame_len >= 42U) {
                    printf("guest_net: rx arp from %u.%u.%u.%u\n",
                           buf[28], buf[29], buf[30], buf[31]);
                } else if (eth_type == 0x0800U && frame_len >= 58U) {
                    char msg[17];
                    memcpy(msg, buf + 42, 16);
                    msg[16] = '\0';
                    printf("guest_net: rx udp4 payload=%s\n", msg);
                } else if (eth_type == 0x86DDU && frame_len >= 79U) {
                    char msg[18];
                    memcpy(msg, buf + 62, 17);
                    msg[17] = '\0';
                    printf("guest_net: rx icmp6 payload=%s\n", msg);
                } else {
                    printf("guest_net: rx eth=0x%04x len=%u\n", eth_type, frame_len);
                }
            }

            /* Replenish RX descriptor */
            uint16_t a_idx = rx_avail->idx;
            rx_avail->ring[a_idx % 8U] = (uint16_t)desc_id;
            __asm__ volatile("" ::: "memory");
            rx_avail->idx = (uint16_t)(a_idx + 1U);
            __asm__ volatile("" ::: "memory");

            g_net_rx_last_used = (uint16_t)(g_net_rx_last_used + 1U);
            received++;
        }
        if (received > 0 && spin > 2000U) break;
    }

    uint32_t irq = mmio_read32(g_net_mmio, VIRTIO_MMIO_INTERRUPT_STATUS);
    if (irq != 0) mmio_write32(g_net_mmio, VIRTIO_MMIO_INTERRUPT_ACK, irq);
    printf("guest_net: rx total=%u\n", received);
}

static const char *base_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static void print_os_release(void) {
    FILE *fp = fopen("/etc/os-release", "r");
    char line[256];

    if (!fp) {
        printf("guest_rootfs: /etc/os-release unavailable\n");
        return;
    }

    while (fgets(line, sizeof(line), fp) != NULL) {
        fputs(line, stdout);
    }

    fclose(fp);
}

static void print_env(char **envp) {
    while (*envp) {
        puts(*envp);
        envp += 1;
    }
}

static int run_shell(char **envp) {
    char line[256];

    printf("guest_rootfs: shell ready\n");
    printf("guest_rootfs: builtins = help, env, os-release, exit\n");

    for (;;) {
        printf("guest-sh$ ");
        if (!fgets(line, sizeof(line), stdin)) {
            printf("guest_rootfs: shell EOF\n");
            return 0;
        }

        line[strcspn(line, "\r\n")] = '\0';
        if (strcmp(line, "") == 0) continue;
        if (strcmp(line, "help") == 0) {
            printf("help env os-release exit\n");
        } else if (strcmp(line, "env") == 0) {
            print_env(envp);
        } else if (strcmp(line, "os-release") == 0) {
            print_os_release();
        } else if (strcmp(line, "blk-test") == 0) {
            run_blk_test();
        } else if (strcmp(line, "net-init") == 0) {
            run_net_init();
        } else if (strcmp(line, "net-spoof") == 0) {
            run_net_spoof();
        } else if (strcmp(line, "net-arp") == 0) {
            run_net_arp();
        } else if (strcmp(line, "net-tx-v4") == 0) {
            run_net_tx_v4();
        } else if (strcmp(line, "net-tx-v6") == 0) {
            run_net_tx_v6();
        } else if (strcmp(line, "net-rx") == 0) {
            run_net_rx();
        } else if (strcmp(line, "exit") == 0) {
            printf("guest_rootfs: shell exit\n");
            return 0;
        } else {
            printf("guest_rootfs: unknown command: %s\n", line);
        }
    }
}

static int run_init(char **envp) {
    printf("guest_rootfs: init started\n");
    printf("guest_rootfs: running from embedded OCI rootfs\n");
    print_os_release();

    const int serial_fd = open("/dev/ttyS0", O_RDWR | O_NOCTTY);
    if (serial_fd < 0) {
        printf("guest_rootfs: cannot open /dev/ttyS0\n");
        for (;;) sleep(60);
    }
    if (dup2(serial_fd, STDIN_FILENO) < 0) {
        printf("guest_rootfs: cannot connect /dev/ttyS0 to stdin\n");
        for (;;) sleep(60);
    }
    if (serial_fd > STDERR_FILENO) close(serial_fd);

    (void)run_shell(envp);
    for (;;) sleep(60);
}

int main(int argc, char **argv, char **envp) {
    const char *prog = base_name(argv[0]);
    (void)argc;

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    if (strcmp(prog, "sh") == 0) {
        return run_shell(envp);
    }
    if (strcmp(prog, "env") == 0) {
        print_env(envp);
        return 0;
    }

    return run_init(envp);
}
