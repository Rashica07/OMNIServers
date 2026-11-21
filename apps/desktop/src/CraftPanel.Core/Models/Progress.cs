namespace CraftPanel.Core;

public sealed record ProvisionProgress(string Stage, string Message, int? Pct = null);

public class ProvisionException(string message, Exception? inner = null) : Exception(message, inner);
