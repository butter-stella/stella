using System.Threading.Tasks;

namespace Natsume.Core.Interfaces
{
    /// <summary>
    /// Presents dialogue to the player. Different implementations handle
    /// different modes: adv (bottom box), nvl (fullscreen), overlay (no box).
    /// </summary>
    public interface IDialoguePresenter
    {
        /// <summary>
        /// The dialogue mode this presenter handles ("adv", "nvl", "overlay").
        /// </summary>
        string Mode { get; }

        Task ShowDialogueAsync(string character, string text, string voiceAssetId = null);
        void Hide();
        void Clear();
    }
}
