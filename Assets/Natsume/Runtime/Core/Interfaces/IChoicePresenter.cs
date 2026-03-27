using System.Threading.Tasks;
using Natsume.Core.Data;

namespace Natsume.Core.Interfaces
{
    /// <summary>
    /// Presents choices to the player and returns the selected option ID.
    /// Different implementations support different styles (text, map, character selection, etc.).
    /// </summary>
    public interface IChoicePresenter
    {
        /// <summary>
        /// The style this presenter handles (corresponds to YAML "style" field).
        /// </summary>
        string Style { get; }

        /// <summary>
        /// Display the choices and wait for the player to select one.
        /// Returns the selected option's ID.
        /// </summary>
        Task<string> ShowAndWaitAsync(ChoiceData data);
    }
}
