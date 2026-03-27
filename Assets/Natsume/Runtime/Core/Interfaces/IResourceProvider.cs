using System.Threading.Tasks;

namespace Natsume.Core.Interfaces
{
    /// <summary>
    /// Abstracts resource loading (sprites, audio, prefabs, etc.).
    /// Default implementation uses Addressables; can be replaced for testing or alternative backends.
    /// </summary>
    public interface IResourceProvider
    {
        Task<T> LoadAsync<T>(string path) where T : class;
        void Release(string path);
        void ReleaseAll();
    }
}
