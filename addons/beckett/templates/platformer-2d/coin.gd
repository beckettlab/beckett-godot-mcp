extends Area2D
func _ready() -> void:
	body_entered.connect(_on_body)
func _on_body(body: Node2D) -> void:
	if not body is CharacterBody2D:
		return
	set_deferred("monitoring", false)
	get_tree().current_scene.add_score(1)
	get_tree().current_scene.burst(global_position, Color("ffcd75"))
	var t := create_tween()
	t.tween_property(self, "scale", Vector2(1.6, 1.6), 0.12)
	t.parallel().tween_property(self, "modulate:a", 0.0, 0.12)
	t.tween_callback(queue_free)
