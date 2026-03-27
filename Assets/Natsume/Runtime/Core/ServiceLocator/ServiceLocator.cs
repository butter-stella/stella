using System;
using System.Collections.Generic;

namespace Natsume.Core.ServiceLocator
{
    /// <summary>
    /// Global service registry. Replaces singletons with a centralized,
    /// testable service access point.
    /// </summary>
    public static class ServiceLocator
    {
        private static readonly Dictionary<Type, object> _services = new Dictionary<Type, object>();

        public static void Register<T>(T instance) where T : class
        {
            if (instance == null)
                throw new ArgumentNullException(nameof(instance));
            _services[typeof(T)] = instance;
        }

        public static T Get<T>() where T : class
        {
            if (_services.TryGetValue(typeof(T), out var service))
                return (T)service;
            throw new InvalidOperationException(
                $"Service of type {typeof(T).Name} is not registered. " +
                "Did you forget to call NatsumeRuntime.Initialize()?");
        }

        public static bool TryGet<T>(out T service) where T : class
        {
            if (_services.TryGetValue(typeof(T), out var obj))
            {
                service = (T)obj;
                return true;
            }
            service = null;
            return false;
        }

        public static bool IsRegistered<T>() where T : class
        {
            return _services.ContainsKey(typeof(T));
        }

        public static void Unregister<T>() where T : class
        {
            _services.Remove(typeof(T));
        }

        /// <summary>
        /// Remove all registered services. Used for test teardown.
        /// </summary>
        public static void Clear()
        {
            _services.Clear();
        }
    }
}
