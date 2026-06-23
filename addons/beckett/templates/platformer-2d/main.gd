extends Node2D
var score := 0
var _over := false
func add_score(n: int) -> void:
	score += n
	var lbl: Label = $HUD/Score
	lbl.text = "Score: %d" % score
	lbl.pivot_offset = lbl.size / 2.0
	lbl.scale = Vector2(1.3, 1.3)
	create_tween().tween_property(lbl, "scale", Vector2.ONE, 0.15)
func burst(at: Vector2, color: Color) -> void:
	var p := CPUParticles2D.new()
	add_child(p)
	p.position = at
	p.one_shot = true
	p.amount = 12
	p.lifetime = 0.4
	p.spread = 180.0
	p.initial_velocity_min = 60.0
	p.initial_velocity_max = 140.0
	p.color = color
	p.finished.connect(p.queue_free)
	p.emitting = true
func shake() -> void:
	var t := create_tween()
	for i in 4:
		t.tween_property($Camera2D, "offset", Vector2(randf_range(-8, 8), randf_range(-8, 8)), 0.04)
	t.tween_property($Camera2D, "offset", Vector2.ZERO, 0.04)
func game_over() -> void:
	if _over:
		return
	_over = true
	shake()
	await get_tree().create_timer(0.3).timeout
	get_tree().paused = true
	$HUD/GameOver.visible = true
func _on_retry() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()
