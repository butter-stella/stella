## Choice data presented to the player during a choice command.
class_name ChoiceData extends RefCounted

var prompt: String = ""
var options: Array = []  # Array[ChoiceOption]


class ChoiceOption extends RefCounted:
	var id: String = ""
	var label: String = ""
	var jump: String = ""
	var set_vars: Dictionary = {}  # var_name -> operation string (e.g. "+5")
	var condition: String = ""     # expression string for conditional display
