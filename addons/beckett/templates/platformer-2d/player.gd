extends CharacterBody2D
const SPEED := 260.0
const JUMP := -600.0
const GRAV_MULT := 2.0
var _coyote := 0.0
var _buffer := 0.0
func _physics_process(delta: float) -> void:
	if is_on_floor():
		_coyote = 0.1
	else:
		velocity += get_gravity() * GRAV_MULT * delta
		_coyote -= delta
	_buffer = 0.1 if Input.is_action_just_pressed("ui_accept") else _buffer - delta
	if _buffer > 0.0 and _coyote > 0.0:
		velocity.y = JUMP
		_buffer = 0.0
		_coyote = 0.0
		squash()
	if Input.is_action_just_released("ui_accept") and velocity.y < 0.0:
		velocity.y *= 0.5
	velocity.x = move_toward(velocity.x, Input.get_axis("ui_left", "ui_right") * SPEED, SPEED * 10.0 * delta)
	var was_air := not is_on_floor()
	move_and_slide()
	position.x = clampf(position.x, 14.0, 1138.0)
	if was_air and is_on_floor():
		squash()
func squash() -> void:
	$Visual.scale = Vector2(1.15, 0.85)
	create_tween().tween_property($Visual, "scale", Vector2.ONE, 0.12)
