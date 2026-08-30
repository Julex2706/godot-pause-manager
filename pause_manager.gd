extends Node
## PauseManager — centralized, group-based selective pausing.
##
## Register as an autoload named "PauseManager" in Project Settings.
##
## Nodes opt into pause contexts through groups named:
##     pause_on_<pause_type>
##
## Example group naming:
##     pause_on_menu
##     pause_on_dialogue
##     pause_on_cutscene
##
## Contract: assign a node's pause_on_* group membership before it enters the
## scene tree. Group mutations after that point aren't watched — only tree
## entry is (see _on_node_added).
##
## Contract: pause-managed nodes should use an explicit process_mode
## (PAUSABLE, WHEN_PAUSED, ALWAYS, or DISABLED). PauseManager does not walk
## the parent chain to resolve PROCESS_MODE_INHERIT.
##
## PROCESS_MODE_INHERIT remains INHERIT in both states. This means an INHERIT
## node may still effectively process according to its parent. This is a
## deliberate limitation rather than automatic inheritance resolution.
##
## PauseManager tracks pause reasons independently. If a node is affected by
## multiple pause types, unpausing one type does not resume the node until
## all applicable pause reasons have been removed.
##
## Overrides temporarily exempt a node from the effective pause state without
## removing any of its underlying pause reasons.

# Extend this enum with any additional pause contexts your game needs.
enum PauseType {
	MENU,
	DIALOGUE,
	CUTSCENE,
}

# For each authored process_mode, what mode a node should have while a pause
# reason applies ("paused") vs. while none applies ("active").
#
# "active" always equals the key itself.
# "paused" also equals the key itself, EXCEPT:
# - PAUSABLE: paused = DISABLED (the normal pausing case).
# - WHEN_PAUSED: paused = ALWAYS (this mode means "only run while paused,"
#   so when PauseManager pauses it, it should be let loose to run).
const _MODE_BEHAVIOR: Dictionary = {
	Node.PROCESS_MODE_INHERIT: {
		"paused": Node.PROCESS_MODE_INHERIT,
		"active": Node.PROCESS_MODE_INHERIT,
	},
	Node.PROCESS_MODE_PAUSABLE: {
		"paused": Node.PROCESS_MODE_DISABLED,
		"active": Node.PROCESS_MODE_PAUSABLE,
	},
	Node.PROCESS_MODE_WHEN_PAUSED: {
		"paused": Node.PROCESS_MODE_ALWAYS,
		"active": Node.PROCESS_MODE_WHEN_PAUSED,
	},
	Node.PROCESS_MODE_ALWAYS: {
		"paused": Node.PROCESS_MODE_ALWAYS,
		"active": Node.PROCESS_MODE_ALWAYS,
	},
	Node.PROCESS_MODE_DISABLED: {
		"paused": Node.PROCESS_MODE_DISABLED,
		"active": Node.PROCESS_MODE_DISABLED,
	},
}

# PauseType -> true, for every currently active pause type.
var _active_types: Dictionary = {}

# Node -> { PauseType: true }, the set of active reasons currently affecting
# a node.
var _node_reasons: Dictionary = {}

# Node -> true, for every node currently overridden.
var _overridden_nodes: Dictionary = {}

# Node -> its process_mode as authored, captured before we ever touch it.
#
# Ownership contract: once a node is tracked here, this dictionary is the
# source of truth for what "active" should restore it to. Even if another
# system changes node.process_mode later, PauseManager will restore the mode
# it first captured, not whatever the node currently has.
var _authored_modes: Dictionary = {}

func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Activates a pause type and pauses all nodes belonging to its group.
func pause(type: PauseType) -> void:
	if _active_types.has(type):
		return
	_active_types[type] = true
	for node in get_tree().get_nodes_in_group(_group_name_for(type)):
		_add_reason(node, type)

## Deactivates a pause type.
##
## Nodes affected by other active pause types remain paused.
func unpause(type: PauseType) -> void:
	if not _active_types.has(type):
		return
	_active_types.erase(type)
	for node in get_tree().get_nodes_in_group(_group_name_for(type)):
		_remove_reason(node, type)

## Temporarily exempts a node from its effective pause state.
##
## This does not remove any underlying pause reasons.
func override(node: Node) -> void:
	if not is_instance_valid(node) or _overridden_nodes.has(node):
		return
	_ensure_tracked(node)
	_overridden_nodes[node] = true
	_apply_effective_state(node)

## Removes a node's pause override.
##
## The node immediately returns to whatever state its current pause reasons
## require.
func remove_override(node: Node) -> void:
	if not _overridden_nodes.has(node):
		return
	_overridden_nodes.erase(node)
	_apply_effective_state(node)

## Returns whether the node is currently considered paused by PauseManager.
##
## An overridden node returns false even if it still has active pause reasons.
func is_node_paused(node: Node) -> bool:
	if _overridden_nodes.has(node):
		return false
	return (
		_node_reasons.has(node)
		and not (_node_reasons[node] as Dictionary).is_empty()
	)

## Returns whether a pause type is currently active.
func is_type_active(type: PauseType) -> bool:
	return _active_types.has(type)

## Returns whether the node is currently overridden by PauseManager.
func is_overridden(node: Node) -> bool:
	return _overridden_nodes.has(node)

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _group_name_for(type: PauseType) -> StringName:
	var key: String = PauseType.keys()[type].to_lower()
	return StringName("pause_on_%s" % key)

func _ensure_tracked(node: Node) -> void:
	if not _authored_modes.has(node):
		_authored_modes[node] = node.process_mode
		_watch_node(node)

func _add_reason(node: Node, type: PauseType) -> void:
	if not is_instance_valid(node):
		return
	_ensure_tracked(node)
	if not _node_reasons.has(node):
		_node_reasons[node] = {}
	(_node_reasons[node] as Dictionary)[type] = true
	_apply_effective_state(node)

func _remove_reason(node: Node, type: PauseType) -> void:
	if not _node_reasons.has(node):
		return
	var reasons: Dictionary = _node_reasons[node]
	reasons.erase(type)
	if reasons.is_empty():
		_node_reasons.erase(node)
	_apply_effective_state(node)

func _apply_effective_state(node: Node) -> void:
	if not is_instance_valid(node):
		return
	var authored_mode: int = _authored_modes.get(node, node.process_mode)
	var behavior: Dictionary = _MODE_BEHAVIOR.get(
		authored_mode,
		_MODE_BEHAVIOR[Node.PROCESS_MODE_INHERIT]
	)
	var has_reason := (
		_node_reasons.has(node)
		and not (_node_reasons[node] as Dictionary).is_empty()
	)
	var should_be_paused := (
		has_reason
		and not _overridden_nodes.has(node)
	)
	node.process_mode = (
		behavior["paused"]
		if should_be_paused
		else behavior["active"]
	)

func _watch_node(node: Node) -> void:
	if not node.tree_exiting.is_connected(_on_node_tree_exiting):
		node.tree_exiting.connect(
			_on_node_tree_exiting.bind(node)
		)

func _on_node_tree_exiting(node: Node) -> void:
	_node_reasons.erase(node)
	_overridden_nodes.erase(node)
	_authored_modes.erase(node)

func _on_node_added(node: Node) -> void:
	for type in _active_types.keys():
		if node.is_in_group(_group_name_for(type)):
			_add_reason(node, type)
