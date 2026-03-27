namespace Natsume.Core.Data
{
    /// <summary>
    /// Semantic input actions, abstracted from physical input devices.
    /// </summary>
    public enum InputAction
    {
        Advance,
        Cancel,
        ShowMenu,
        HistoryPrev,
        HistoryNext,
        ToggleAuto,
        ToggleSkip,
        HideUI,
        QuickSave,
        QuickLoad
    }
}
