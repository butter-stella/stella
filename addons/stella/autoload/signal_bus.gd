## Global signal bus for decoupling Core and Presentation layers.
## Registered as an Autoload singleton.
extends Node

# Dialogue
## Unified dialogue signal — both normal and @combine dialogues flow through here.
## segments: Array of {text: String, voice: String, expression: String}
## A normal single-line dialogue has segments.size() == 1. A @combine block has
## multiple segments; voices play sequentially, expression switches at each
## segment boundary. Either way, the dialogue is one unit for advance/skip/backlog.
signal show_dialogue(character: String, segments: Array, mode: String)
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

## High-level dialogue voice signals — emitted by DialoguePresenter so that
## a @combine block (or any dialogue with multiple segment voices) is treated
## as one logical playback for UI purposes (e.g. a single continuous progress
## bar instead of one bar per segment). For a normal single-voice dialogue
## these mirror voice_started / voice_progress / voice_finished 1:1.
signal dialogue_voice_started(total_duration: float)
signal dialogue_voice_progress(position: float, total_duration: float)
signal dialogue_voice_finished()

## Request that DialoguePresenter replay an arbitrary list of voice assets as
## one logical dialogue (uses the same voice queue + progress bar machinery as
## the in-game replay button). Used by the backlog screen so that:
##   - the progress bar reflects the full combined duration
##   - playback state lives in the always-present DialoguePresenter, so closing
##     the backlog overlay does NOT cancel the audio
##   - advancing to the next in-game dialogue cleanly cancels any in-flight
##     replay via the same _dialogue_gen mechanism
signal dialogue_voice_replay_requested(voices: Array, character: String)

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
