## Authoritative CanvasLayer ordering shared by Runtime-owned presentation.
class_name PresentationLayerOrder extends RefCounted

## Full-screen authored media sits above story UI (3) and below screen flash
## effects (100). Movie and presentation clip are mutually exclusive owners.
const FULLSCREEN_MEDIA := 90

## Runtime screen flash is the deterministic top authored presentation surface.
## ScreenEffects may still opt into an explicit project-owned override.
const SCREEN_FLASH := 100
