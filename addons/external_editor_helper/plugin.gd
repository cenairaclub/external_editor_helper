@tool
extends EditorPlugin

func _enter_tree():
	print("External Editor Helper: Plugin loaded")

func _exit_tree():
	print("External Editor Helper: Plugin unloaded")

func _handles(object):
	return true

func _input(event):
	if event is InputEventKey and event.pressed and not event.echo:
		#! Ctrl+Shift+C: Copy @onready variables for selected scene nodes
		if event.ctrl_pressed and event.shift_pressed and event.keycode == KEY_C:
			_handle_scene_copy()
			#! Ctrl+Shift+R: Copy resource paths from filesystem
		elif event.ctrl_pressed and event.shift_pressed and event.keycode == KEY_R:
			_handle_filesystem_copy()

func _handle_scene_copy():
	var copyTo : String
	var selection = EditorInterface.get_selection()
	var selected_nodes = selection.get_selected_nodes()

	if selected_nodes.is_empty():
		print("No nodes selected")
		return
		
	change_unique_names_with_undo(selected_nodes)
	
	var code_lines = []
	for node in selected_nodes:
		if not is_instance_valid(node):
			continue

		var var_name = _to_snake_case(node.name)
		var node_type = node.get_class()
		var node_path = _get_node_path(node)

		code_lines.append("@onready var %s: %s = %%%s" % [var_name, node_type, node.name])
		
	if code_lines.size() > 0:
		copyTo = "\n".join(code_lines)
	else:
		print("No valid nodes to process")
	
	await get_tree().create_timer(0.1).timeout # Without this timer, it won't work
	DisplayServer.clipboard_set(copyTo)
	print("✅ Copied %d @onready variables to clipboard!" % code_lines.size())

func change_unique_names_with_undo(nodes: Array[Node]):
	var undo_redo = EditorInterface.get_editor_undo_redo()

	var action_name = "Unique Names Enabled" 
	undo_redo.create_action(action_name)

	for node in nodes:
		if node != null and is_instance_valid(node) and node.unique_name_in_owner == false:
			undo_redo.add_do_method(node, "set_unique_name_in_owner", true)
			undo_redo.add_undo_method(node, "set_unique_name_in_owner", false)

	undo_redo.commit_action()
	
func _handle_filesystem_copy():
	var fs_dock = EditorInterface.get_file_system_dock()
	if not fs_dock:
		print("Cannot access filesystem dock")
		return

	var selected_paths = _get_selected_filesystem_paths()

	if selected_paths.is_empty():
		print("No files selected in filesystem")
		return

	var statements = []
	for path in selected_paths:
		var file_name = path.get_file().get_basename()
		var var_name = _to_snake_case(file_name)

		# Determine the appropriate loading method based on file extension
		var extension = path.get_extension().to_lower()
		var load_statement = ""

		match extension:
			"tscn":
				load_statement = "var %s = preload(\"%s\")" % [var_name, path]
			"gd", "cs":
				load_statement = "var %s = preload(\"%s\")" % [var_name, path]
			_:
				load_statement = "var %s = preload(\"%s\")" % [var_name, path]

		statements.append(load_statement)

	var result = "\n".join(statements)
	DisplayServer.clipboard_set(result)
	print("✅ Copied %d preload statements to clipboard!" % statements.size())

func _get_selected_filesystem_paths() -> PackedStringArray:
	var selected_paths = PackedStringArray()

	var selected = EditorInterface.get_selected_paths()

	if selected.is_empty():
		print("No paths selected via EditorInterface")

		var fs_dock = EditorInterface.get_file_system_dock()
		if fs_dock and fs_dock.has_method("get_selected_paths"):
			selected = fs_dock.get_selected_paths()
			print("Trying FileSystemDock.get_selected_paths(): ", selected)

		if selected.is_empty():
			selected = _try_get_from_tree()

	for path in selected:
		if FileAccess.file_exists(path):
			selected_paths.append(path)
		elif DirAccess.dir_exists_absolute(path):
			print("Skipping directory: ", path, " (use file selection instead)")

	return selected_paths

func _try_get_from_tree() -> PackedStringArray:
	var selected_paths = PackedStringArray()
	var fs_dock = EditorInterface.get_file_system_dock()
	if not fs_dock:
		return selected_paths

	var tree = _find_tree_in_dock(fs_dock)
	if not tree:
		print("Could not find Tree in FileSystemDock")
		return selected_paths

	var selected_items = []
	var root = tree.get_root()
	if root:
		_collect_selected_items(root, selected_items)

	print("Found ", selected_items.size(), " selected items in tree")

	for item in selected_items:
		var path = _get_item_path(item)
		if path != "" and FileAccess.file_exists(path):
			selected_paths.append(path)
			print("Tree item path: ", path)

	return selected_paths

func _collect_selected_items(item: TreeItem, collected: Array):
	if item.is_selected(0):
		collected.append(item)

	var child = item.get_first_child()
	while child:
		_collect_selected_items(child, collected)
		child = child.get_next()

func _get_item_path(item: TreeItem) -> String:
	var metadata = item.get_metadata(0)
	if metadata and typeof(metadata) == TYPE_STRING:
		var path = str(metadata)
		if path.begins_with("res://"):
			return path

	var path_parts = []
	var current_item = item

	while current_item != null:
		var text = current_item.get_text(0)
		if text != "" and text != "res://":
			path_parts.push_front(text)
		current_item = current_item.get_parent()

	if path_parts.size() > 0:
		var constructed_path = "res://" + "/".join(path_parts)
		return constructed_path

	return ""

func _find_tree_in_dock(parent: Node) -> Tree:
	if parent is Tree:
		return parent

	for child in parent.get_children():
		var result = _find_tree_in_dock(child)
		if result:
			return result
	return null

func _get_node_path(node: Node) -> String:
	var edited_scene = EditorInterface.get_edited_scene_root()
	if not edited_scene:
		return '$"%s"' % node.name

	var path = edited_scene.get_path_to(node)
	if path.is_empty():
		return '$"%s"' % node.name

	var path_string = str(path)
	if path_string.contains(" ") or path_string.contains("-") or not path_string.is_valid_identifier():
		return '$"%s"' % path_string
	else:
		return "$%s" % path_string

func _to_snake_case(text: String) -> String:
	if text.is_empty():
		return "item"

	var result = ""

	for i in text.length():
		var char = text[i]
		# Add underscore before uppercase letters (except first character)
		if i > 0 and char >= "A" and char <= "Z":
			result += "_"
		result += char.to_lower()

	# Replace invalid characters with underscores
	result = result.replace(" ", "_").replace("-", "_").replace(".", "_")

	# Remove consecutive underscores
	while result.contains("__"):
		result = result.replace("__", "_")

	# Keep only valid characters (letters, numbers, underscores)
	var cleaned = ""
	for char in result:
		if (char >= "a" and char <= "z") or (char >= "0" and char <= "9") or char == "_":
			cleaned += char
	result = cleaned

	# Ensure it doesn't start with a number
	if result.length() > 0 and result[0] >= "0" and result[0] <= "9":
		result = "_" + result

	# Remove leading/trailing underscores
	result = result.strip_edges().lstrip("_").rstrip("_")

	# Fallback if empty or only underscores
	if result.is_empty() or result.replace("_", "").is_empty():
		result = "item"

	return result
	