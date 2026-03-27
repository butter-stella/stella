using Natsume.Core.Data;

namespace Natsume.Core.Interfaces
{
    /// <summary>
    /// Abstracts input handling. Maps physical input to semantic actions.
    /// Implementations: DesktopInputProvider, MobileInputProvider, etc.
    /// </summary>
    public interface IInputProvider
    {
        bool IsActionTriggered(InputAction action);
    }
}
