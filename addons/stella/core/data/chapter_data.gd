## A chapter — narrative grouping unit (issue #97).
## Chapters are author-declared via @chapter in DSL and contain one or more
## scenes. They are the granularity of the flowchart feature: each chapter is
## one node in the scenario graph; cross-chapter transitions are edges.
class_name ChapterData extends RefCounted

var id: String = ""
var display_name: String = ""
var scene_ids: Array = []  # Array[String], in declaration order
## Source line of the @chapter directive (1-based). Set by DslParser; 0 for
## chapters constructed manually (e.g. in tests bypassing the parser).
## Used by post-parse validation to give empty-chapter errors a real line.
var declared_line: int = 0
