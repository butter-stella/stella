using System.Threading.Tasks;

namespace Natsume.Core.Interfaces
{
    /// <summary>
    /// Abstracts resource loading (sprites, audio, prefabs, etc.).
    /// Default implementation uses Addressables; can be replaced for testing or alternative backends.
    /// </summary>
    public interface IResourceProvider
    {
        /// <summary>
        /// Load a resource asynchronously by path.
        /// Constrained to reference types because Unity assets (Texture2D, AudioClip, etc.)
        /// are all classes, and value types are not Addressable-loadable.
        /// </summary>
        Task<T> LoadAsync<T>(string path) where T : class;
        void Release(string path);
        void ReleaseAll();
    }
}
