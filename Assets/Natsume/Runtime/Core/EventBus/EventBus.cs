using System;
using System.Collections.Generic;
using Natsume.Core.Events;

namespace Natsume.Core.EventBus
{
    /// <summary>
    /// Global event bus for decoupled communication between systems.
    /// Core layer publishes events, Presentation layer subscribes and responds.
    /// </summary>
    public static class EventBus
    {
        private static readonly Dictionary<Type, Delegate> _handlers = new Dictionary<Type, Delegate>();

        /// <summary>
        /// Replaceable logger for exception reporting. Defaults to System.Diagnostics.
        /// Presentation layer should replace with UnityEngine.Debug.LogWarning at init.
        /// </summary>
        public static Action<string> Logger { get; set; } = System.Diagnostics.Debug.WriteLine;

        /// <summary>
        /// Subscribe a handler for events of type T.
        /// To unsubscribe later, store the handler reference. Lambda expressions
        /// create a new delegate instance each time and cannot be matched by Delegate.Remove.
        /// </summary>
        public static void Subscribe<T>(Action<T> handler) where T : IEvent
        {
            if (handler == null)
                throw new ArgumentNullException(nameof(handler));

            var type = typeof(T);
            if (_handlers.TryGetValue(type, out var existing))
                _handlers[type] = Delegate.Combine(existing, handler);
            else
                _handlers[type] = handler;
        }

        public static void Unsubscribe<T>(Action<T> handler) where T : IEvent
        {
            if (handler == null)
                throw new ArgumentNullException(nameof(handler));

            var type = typeof(T);
            if (_handlers.TryGetValue(type, out var existing))
            {
                var result = Delegate.Remove(existing, handler);
                if (result == null)
                    _handlers.Remove(type);
                else
                    _handlers[type] = result;
            }
        }

        public static void Publish<T>(T evt) where T : IEvent
        {
            var type = typeof(T);
            if (!_handlers.TryGetValue(type, out var existing))
                return;

            foreach (var d in existing.GetInvocationList())
            {
                try
                {
                    ((Action<T>)d).Invoke(evt);
                }
                catch (Exception e)
                {
                    Logger?.Invoke($"[EventBus] Exception in handler for {type.Name}: {e}");
                }
            }
        }

        /// <summary>
        /// Remove all subscribers. Used for test teardown.
        /// </summary>
        public static void Clear()
        {
            _handlers.Clear();
        }
    }
}
