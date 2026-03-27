using System;
using System.Collections.Generic;

namespace Natsume.Core.Commands
{
    /// <summary>
    /// Registry for command handlers. Maps command type strings to handler instances.
    /// </summary>
    public class CommandRegistry
    {
        private readonly Dictionary<string, ICommandHandler> _handlers = new Dictionary<string, ICommandHandler>();

        public void Register(ICommandHandler handler)
        {
            if (handler == null)
                throw new ArgumentNullException(nameof(handler));
            _handlers[handler.CommandType] = handler;
        }

        public ICommandHandler GetHandler(string commandType)
        {
            _handlers.TryGetValue(commandType, out var handler);
            return handler;
        }

        public bool HasHandler(string commandType)
        {
            return _handlers.ContainsKey(commandType);
        }
    }
}
