## A scene within a scenario, containing an ordered list of commands.
class_name SceneData extends RefCounted

var id: String = ""
var commands: Array = []  # Array[CommandData]
## Back-reference to the chapter this scene belongs to (issue #97).
## Set by DslParser at parse time. Empty string means orphan (parser error).
var chapter_id: String = ""
