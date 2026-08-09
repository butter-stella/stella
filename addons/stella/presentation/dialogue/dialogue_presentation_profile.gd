## Advanced scene-side fallback for ADV/NVL/overlay presentation.
##
## Normal projects should author named profiles in STLA with @dialogue_profile.
## Assign this Resource to DialoguePresenter.presentation_profile only when a
## special scene or programmatic integration cannot be expressed in STLA.
class_name DialoguePresentationProfile
extends Resource

@export var adv: DialogueModeProfile
@export var nvl: DialogueModeProfile
@export var overlay: DialogueModeProfile


func get_mode(mode: String) -> DialogueModeProfile:
	match mode:
		"adv":
			return adv
		"nvl":
			return nvl
		"overlay":
			return overlay
	return null
