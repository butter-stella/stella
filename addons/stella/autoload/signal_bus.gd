## Global signal bus for decoupling Core and Presentation layers.
## Registered as an Autoload singleton.
extends Node

# Dialogue
signal show_dialogue(character: String, text: String, voice: String, mode: String)
signal hide_dialogue()
signal advance_requested()

# Character
signal char_show(character: String, expression: String, position: String)
signal char_hide(character: String)
signal char_expression_changed(character: String, expression: String)
signal char_anim_requested(character: String, anim: String, intensity: String)
signal char_move_requested(character: String, position: String, duration: float)

# Background
signal bg_changed(asset: String, transition: String, duration: float)

# Audio
signal bgm_play(asset: String, fade_duration: float)
signal bgm_stop(fade_duration: float)
signal se_play(asset: String, loop: bool)
signal se_stop(asset: String)
signal voice_play(asset: String, character: String)
signal system_se_play(asset: String)
signal voice_started(character: String, asset: String)
signal voice_finished()
signal voice_progress(position: float, duration: float)

# Choice
signal choice_show(prompt: String, options: Array)
signal choice_selected(option_id: String)

# CG
signal cg_show(asset: String, mode: String, transition: String, duration: float)
signal cg_hide(transition: String, duration: float)

# Effects
signal effect_requested(effect_type: String, params: Dictionary)
signal fade_requested(direction: String, duration: float)

# System
signal scenario_started_event(scenario_id: String)
signal scenario_ended_event(scenario_id: String)
signal scene_changed_event(scene_id: String)
signal variable_changed(var_name: String, value: Variant)
signal settings_changed(key: String, value: Variant)
