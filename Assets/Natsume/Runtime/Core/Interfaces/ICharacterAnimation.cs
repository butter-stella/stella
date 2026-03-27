using System.Threading.Tasks;

namespace Natsume.Core.Interfaces
{
    /// <summary>
    /// Defines a character animation preset (jump, shake, nod, etc.).
    /// Register custom implementations to extend the built-in set.
    /// </summary>
    public interface ICharacterAnimation
    {
        /// <summary>
        /// The animation name (corresponds to YAML "anim" field).
        /// </summary>
        string AnimationName { get; }

        /// <summary>
        /// Play the animation on a character.
        /// </summary>
        /// <param name="characterId">Target character.</param>
        /// <param name="intensity">Animation intensity (0~1). Mapped from light/normal/strong aliases.</param>
        /// <param name="duration">Duration in seconds. 0 = use default.</param>
        Task PlayAsync(string characterId, float intensity = 0.5f, float duration = 0f);
    }
}
