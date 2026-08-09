## A scene within a scenario, containing an ordered list of commands.
class_name SceneData extends RefCounted

var id: String = ""
var commands: Array = []  # Array[CommandData]
## Back-reference to the chapter this scene belongs to (issue #97).
## Set by DslParser at parse time. Empty string means orphan (parser error).
var chapter_id: String = ""
## Source line of the @scene directive (1-based). Set by DslParser; 0 for
## scenes constructed manually (e.g. tests bypassing the parser) or for
## synthetic @if/@elif scenes (which inherit from their parent's chapter
## but are not author-declared).
var declared_line: int = 0
## Dialogue mode transitions that execute when this scene is naturally
## exhausted, before sequential fallthrough or an @call return. Kept outside
## commands so existing command indices and persisted return points stay stable.
var dialogue_mode_events_on_exit: Array[String] = []
