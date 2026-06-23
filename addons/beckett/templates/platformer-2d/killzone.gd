extends Area2D
func _ready() -> void:
	body_entered.connect(_on_body)
func _on_body(body: Node2D) -> void:
	if body is CharacterBody2D:
		get_tree().current_scene.game_over()
