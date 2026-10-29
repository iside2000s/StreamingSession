using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json;

namespace FoveatedStreaming.WindowsSample
{
    // Opt-in only. The normal sample remains single-session when the launcher
    // has not supplied STREAMING_EXPERIMENT_CONFIG in the child environment.
    internal sealed class ExperimentalSeatConfiguration
    {
        private static readonly Lazy<ExperimentalSeatConfiguration> Configuration =
            new Lazy<ExperimentalSeatConfiguration>(Load);
        private readonly object fileLock = new object();
        public static ExperimentalSeatConfiguration Current => Configuration.Value;
        public string SeatId { get; set; }
        public string DisplayName { get; set; }
        public string HostAddress { get; set; }
        public int SessionPort { get; set; }
        public int SignalingPort { get; set; }
        public int MediaPort { get; set; }
        public string StateDirectory { get; set; }
        public string RouteDirectory { get; set; }
        public string BundleId { get; set; }
        public string RuntimeVersion { get; set; } = "6.2.3";
        public bool AutoStart { get; set; } = true;
        [JsonIgnore] public string TemporaryDirectory => Path.Combine(StateDirectory, "tmp");
        [JsonIgnore] public string RuntimeConfigurationPath => Path.Combine(StateDirectory, "runtime.yaml");
        [JsonIgnore] public string RoutePath => Path.Combine(RouteDirectory, SeatId + ".route.json");
        [JsonIgnore] public string LogPath => Path.Combine(StateDirectory, "seat.log");
        [JsonIgnore] public string RpcPipeName
        {
            get
            {
                using (var hash = SHA256.Create())
                {
                    string suffix = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(StateDirectory.ToUpperInvariant()))).Replace("-", "").Substring(0, 12);
                    return "streaming-experiment-" + SeatId + "-" + suffix;
                }
            }
        }

        private static ExperimentalSeatConfiguration Load()
        {
            string path = Environment.GetEnvironmentVariable("STREAMING_EXPERIMENT_CONFIG");
            if (string.IsNullOrWhiteSpace(path)) return null;
            var config = JsonConvert.DeserializeObject<ExperimentalSeatConfiguration>(File.ReadAllText(path));
            if (config == null || (config.SeatId != "a" && config.SeatId != "b"))
                throw new InvalidOperationException("Experimental SeatId must be a or b.");
            IPAddress address;
            if (!IPAddress.TryParse(config.HostAddress, out address) || address.AddressFamily != AddressFamily.InterNetwork)
                throw new InvalidOperationException("Experimental HostAddress must be an IPv4 address.");
            foreach (int port in new[] { config.SessionPort, config.SignalingPort, config.MediaPort })
                if (port < 1024 || port > 65535) throw new InvalidOperationException("Invalid experimental port.");
            if (config.SessionPort == config.SignalingPort || config.SessionPort == config.MediaPort || config.SignalingPort == config.MediaPort)
                throw new InvalidOperationException("Each experimental port must be distinct.");
            if (string.IsNullOrWhiteSpace(config.BundleId) || string.IsNullOrWhiteSpace(config.DisplayName))
                throw new InvalidOperationException("Experimental BundleId and DisplayName are required.");
            config.StateDirectory = Path.GetFullPath(config.StateDirectory);
            config.RouteDirectory = Path.GetFullPath(config.RouteDirectory);
            string temporaryDirectory = Path.GetFullPath(Environment.GetEnvironmentVariable("TMP") ?? "").TrimEnd('\\');
            if (!string.Equals(temporaryDirectory, config.TemporaryDirectory.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Start this seat using Start-HeadsetTest.ps1 so its temporary directory is inherited before startup.");
            Directory.CreateDirectory(config.StateDirectory);
            Directory.CreateDirectory(config.RouteDirectory);
            config.ClearRoute();
            config.Log("START " + config.SeatId + " management=" + config.HostAddress + ":" + config.SessionPort + " signaling=" + config.SignalingPort);
            return config;
        }

        public string ServerId
        {
            get
            {
                lock (fileLock)
                {
                    string path = Path.Combine(StateDirectory, "server-id.txt");
                    Guid value;
                    if (File.Exists(path) && Guid.TryParse(File.ReadAllText(path), out value)) return value.ToString("N");
                    string created = Guid.NewGuid().ToString("N");
                    File.WriteAllText(path, created);
                    return created;
                }
            }
        }

        public void RegisterClient(IPAddress address)
        {
            if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
            lock (fileLock)
            {
                File.WriteAllText(RoutePath, JsonConvert.SerializeObject(new
                {
                    SeatId,
                    ClientAddress = address.ToString(),
                    UpdatedUtc = DateTime.UtcNow.ToString("o")
                }));
            }
            Log("CLIENT " + address);
        }

        public void ClearRoute()
        {
            lock (fileLock)
            {
                // Keep a valid JSON document even while the gateway is reading.
                if (File.Exists(RoutePath)) File.WriteAllText(RoutePath, "{}");
            }
        }

        public void Log(string message)
        {
            lock (fileLock)
                File.AppendAllText(LogPath, DateTimeOffset.Now.ToString("o") + " " + message + Environment.NewLine);
        }
    }
}
