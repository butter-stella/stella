using System.Threading.Tasks;

namespace Natsume.Core.Interfaces
{
    /// <summary>
    /// Abstracts character rendering. Implementations handle different render modes:
    /// sprite (full image), layered (body + face), live2d, etc.
    /// </summary>
    public interface ICharacterRenderer
    {
        /// <summary>
        /// The render mode this renderer handles ("sprite", "layered", "live2d").
        /// </summary>
        string RenderMode { get; }

        Task ShowAsync(string characterId, string expression, string position);
        Task HideAsync(string characterId);
        void SetExpression(string characterId, string expression);
    }
}
