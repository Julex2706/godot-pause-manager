# Godot PauseManager

A small, centralized PauseManager for Godot 4 that provides **selective, multi-reason pausing** using Godot groups.

Instead of manually finding and pausing individual nodes, nodes declare which pause contexts affect them through groups such as:

```
pause_on_menu
pause_on_dialogue
pause_on_cutscene
```

The PauseManager keeps track of active pause reasons per node and supports temporary node-level overrides.

## Why?

Godot provides built-in pause functionality through `SceneTree.paused` and `Node.process_mode`. That works well for global pause behavior, but games often need more fine-grained control:

- A pause menu should stop gameplay but keep the menu running.
- Dialogue should stop gameplay while dialogue UI and selected animations continue.
- A cutscene may pause different things than a menu.
- A specific NPC may need to move while the rest of the game remains paused.
- Multiple pause contexts may be active simultaneously.

PauseManager provides a layer on top of Godot's process modes for handling these cases. It is **not** a replacement for Godot's native pause system, but an orchestration layer built on top of it.

## Features

- Group-based selective pausing
- Multiple independent pause types
- Multiple simultaneous pause reasons per node
- Node-level pause overrides
- Preservation of a node's authored `process_mode`
- Automatic handling of nodes entering the scene tree while a pause type is active
- No direct dependency from gameplay nodes on PauseManager
- Extensible pause type enum
- Small public API

## Installation

1. Add `pause_manager.gd` to your project.
2. Register it as an Autoload in **Project Settings → Globals → Autoload**:
   - **Name:** `PauseManager`
   - **Path:** `res://path/to/pause_manager.gd`

The manager is intended to exist globally for the lifetime of the game.

## Pause Types

Pause types are defined by the `PauseType` enum:

```gdscript
enum PauseType {
	MENU,
	DIALOGUE,
	CUTSCENE,
}
```

Extend this enum with any pause contexts required by your project. For example, a project may add contexts for inventory, photo mode, scripted events, or other game-specific states.

### Group Convention

Each pause type corresponds to a Godot group:

```
pause_on_<pause_type>
```

The enum name is converted to lowercase.

| PauseType | Group |
|-----------|-------|
| MENU | pause_on_menu |
| DIALOGUE | pause_on_dialogue |
| CUTSCENE | pause_on_cutscene |

Nodes can belong to multiple pause groups.

### Group Membership Contract

Nodes **must be assigned to their `pause_on_*` groups before entering the scene tree**.

PauseManager watches `SceneTree.node_added` and checks group membership when a node enters the tree. It does not watch later calls to `add_to_group()` or `remove_from_group()`.

Therefore, dynamically changing pause-group membership after tree entry is not automatically detected.

## Public API

### `pause(type: PauseType) -> void`

Activates a pause type. All nodes belonging to the corresponding `pause_on_*` group receive that pause reason.

```gdscript
PauseManager.pause(PauseManager.PauseType.DIALOGUE)
```

Calling `pause()` repeatedly for an already-active type has no additional effect.

### `unpause(type: PauseType) -> void`

Removes a pause type. Only that particular pause reason is removed. If a node is affected by another active pause type, it remains paused.

```gdscript
PauseManager.unpause(PauseManager.PauseType.DIALOGUE)
```

### `override(node: Node) -> void`

Temporarily exempts a specific node from its effective PauseManager pause state. The node's underlying pause reasons are not removed.

```gdscript
PauseManager.override(some_node)
```

### `remove_override(node: Node) -> void`

Removes a node's override. The node immediately returns to the state required by its current pause reasons.

```gdscript
PauseManager.remove_override(some_node)
```

### `is_node_paused(node: Node) -> bool`

Returns whether PauseManager currently considers the node paused. An overridden node returns `false`, even if it still has active pause reasons.

### `is_type_active(type: PauseType) -> bool`

Returns whether a particular pause type is currently active.

## Multiple Pause Reasons

Pause reasons are independent. Conceptually:

```
Node
├── MENU
└── DIALOGUE
```

Removing `MENU` does not resume the node because `DIALOGUE` still applies. Only when all applicable pause reasons have been removed does the node return to its active process mode.

This prevents one system from accidentally unpausing something another system still needs paused.

## Overrides

Overrides are deliberately separate from pause reasons.

An override does not mean: **"Unpause this node."**

It means: **"Ignore the effective pause state for this node for now."**

Therefore, the underlying pause reasons remain intact. This allows a node to temporarily operate without destroying the state that caused it to be paused. When the override is removed, the node is evaluated against its current pause reasons again.

## Process Modes

PauseManager uses Godot's `Node.process_mode` as the mechanism for applying selective pauses.

### Supported Modes

| Authored Mode | Paused State | Active State |
|---------------|--------------|--------------|
| `PAUSABLE` | `DISABLED` | `PAUSABLE` |
| `WHEN_PAUSED` | `ALWAYS` | `WHEN_PAUSED` |
| `ALWAYS` | `ALWAYS` | `ALWAYS` |
| `DISABLED` | `DISABLED` | `DISABLED` |
| `INHERIT` | `INHERIT` | `INHERIT` |

### `PROCESS_MODE_INHERIT`

PauseManager does not resolve process-mode inheritance. An `INHERIT` node remains `INHERIT` while paused and while active.

Therefore, nodes intended to be selectively controlled by PauseManager should use an explicit process mode rather than relying on inheritance.

This is an intentional design constraint.

### Process Mode Ownership

When PauseManager first starts tracking a node, it records the node's current `process_mode`. That value becomes the node's **authored mode** for PauseManager.

The recorded mode is stored internally and used as the source of truth when restoring the node's active state. If another system changes `node.process_mode` after PauseManager has started tracking the node, PauseManager does not adopt that new value as the authored mode.

This is an intentional ownership contract.

## Nodes Entering the Scene Tree

If a pause type is already active when a new node enters the scene tree, PauseManager checks whether the node belongs to that pause type's group.

If it does, the corresponding pause reason is immediately applied.

This allows dynamically spawned nodes to participate in an already-active pause context, provided their group membership was assigned before they entered the tree.

## What PauseManager Does Not Do

PauseManager intentionally does not:

- Toggle `SceneTree.paused`
- Resolve `PROCESS_MODE_INHERIT`
- Watch arbitrary group membership mutations
- Know about specific gameplay classes
- Know about specific scenes
- Require gameplay nodes to reference PauseManager
- Automatically enable nodes authored as `PROCESS_MODE_DISABLED`
- Remove pause reasons when an override is applied

It is a selective process-mode manager, not a replacement for Godot's global pause system.

## Design

The internal state is divided into four concepts:

- **`_active_types`** — Which pause contexts are currently active?
- **`_node_reasons`** — Which active pause reasons affect each node?
- **`_overridden_nodes`** — Which nodes temporarily ignore their effective pause state?
- **`_authored_modes`** — What process mode did each tracked node have when PauseManager first took ownership?

This separation is what allows multiple pause contexts and temporary overrides to coexist safely.

## Extending the System

The primary extension point is `PauseType`. Add another enum value and follow the group naming convention:

```
PauseType.X  →  pause_on_x
```

The rest of the manager automatically uses the corresponding group. Additional project-specific behavior can be built around the public API without requiring participating gameplay nodes to know how PauseManager stores its state.

## Requirements

- Godot 4.x
- GDScript
- Autoload support

## License

MIT License — feel free to use this in your projects.
