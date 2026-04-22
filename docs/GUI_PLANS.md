# GUI Plans for Catenary OS

## Overview
The graphical user interface (GUI) for Catenary OS will be modernized to improve usability and functionality. The focus will be on creating a user-friendly interface for managing MicroVMs and interacting with the system. The following sections outline the planned features and improvements.

---

## Planned Features

### 1. MicroVM Management
- **List of Configured MicroVMs**: Display a table of all configured MicroVMs, including:
  - MicroVM ID
  - Name
  - Assigned Memory (in pages)
  - Number of vCPUs
  - Current State (e.g., Running, Stopped)
- **Container Association**: Show the container each MicroVM is configured to load.
- **Actions**:
  - Start/Stop MicroVMs
  - Delete MicroVMs

### 2. MicroVM Creation
- **Enhanced Creation Workflow**:
  - Specify vCPU count.
  - Assign memory size (in pages).
  - Select kernel and initramfs images.
  - Provide a name for the MicroVM.
- **Validation**: Ensure all required fields are filled before submission.

### 3. Modernized Layout
- **Responsive Design**: Ensure the GUI adapts to different screen sizes and resolutions.
- **Color Scheme**: Use a modern and visually appealing color palette.
- **Interactive Elements**:
  - Buttons for actions (e.g., Create, Start, Stop).
  - Dropdowns and input fields for configuration.

### 4. Varde Shell Integration
- **Positioning**: Place the Varde Shell at the bottom of the screen.
- **Interactive Input**:
  - Allow cursor movement using the TAB key.
  - Support for command history navigation.
- **Real-Time Updates**: Display real-time logs and system messages.

---

## Technical Implementation

### 1. Backend Changes
- **Syscalls**:
  - Add `SYS_FB_DRAW_COLORED` for rendering colored text.
  - Add `SYS_FB_FILL_RECT` for drawing filled rectangles.
  - Add `SYS_TRY_RECV` for non-blocking message reception.
- **Service Updates**:
  - Update `windowd` to handle new syscalls.
  - Allow `windowd` to create MicroVMs via the control handler.

### 2. Frontend Updates
- **Windowd Rewrite**:
  - Use a modern TUI (Text User Interface) layout.
  - Implement a grid-based design for better organization.
- **Input Handling**:
  - Add support for the TAB key in `inputd`.
  - Improve input validation and error handling.

---

## Timeline

### Phase 1: Backend Updates (2 weeks)
- Implement new syscalls.
- Update `windowd` and `inputd` services.

### Phase 2: Frontend Development (3 weeks)
- Rewrite `windowd` with the new TUI layout.
- Integrate Varde Shell into the GUI.

### Phase 3: Testing and Validation (1 week)
- Test the new GUI features.
- Validate MicroVM creation and management workflows.

---

## Conclusion
The updated GUI will provide a more intuitive and powerful interface for managing MicroVMs and interacting with the system. By modernizing the layout and adding new features, we aim to enhance the overall user experience of Catenary OS.