using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;

namespace StreamingSessionExperiments
{
    internal sealed class GatewayRoute
    {
        public string SeatId { get; set; }
        public string ClientRoutePath { get; set; }
        public string BackendAddress { get; set; }
        public int BackendPort { get; set; }
    }

    internal sealed class GatewayConfiguration
    {
        public string ListenAddress { get; set; }
        public int ListenPort { get; set; }
        public string StopFile { get; set; }
        public string ReadyFile { get; set; }
        public string LogFile { get; set; }
        public GatewayRoute[] Routes { get; set; }
    }

    internal sealed class ClientRoute
    {
        public string SeatId { get; set; }
        public string ClientAddress { get; set; }
    }

    // A TCP/TLS byte relay, not a CloudXR protocol implementation. Whether the
    // native media path tolerates this signaling relay requires headset testing.
    internal sealed class SignalingGateway
    {
        private readonly GatewayConfiguration config;
        private readonly object sync = new object();
        private readonly HashSet<TcpClient> active = new HashSet<TcpClient>();
        public SignalingGateway(GatewayConfiguration configuration) { config = configuration; }

        private void Log(string message)
        {
            lock (sync) File.AppendAllText(config.LogFile, DateTimeOffset.Now.ToString("o") + " " + message + Environment.NewLine);
        }

        private GatewayRoute FindRoute(IPAddress peer)
        {
            if (peer.IsIPv4MappedToIPv6) peer = peer.MapToIPv4();
            var matches = new List<GatewayRoute>();
            foreach (var route in config.Routes)
            {
                try
                {
                    if (!File.Exists(route.ClientRoutePath)) continue;
                    var client = JsonConvert.DeserializeObject<ClientRoute>(File.ReadAllText(route.ClientRoutePath));
                    IPAddress registered;
                    if (client != null && client.SeatId == route.SeatId && IPAddress.TryParse(client.ClientAddress, out registered) && registered.Equals(peer))
                        matches.Add(route);
                }
                catch (IOException) { }
                catch (JsonException) { }
            }
            return matches.Count == 1 ? matches[0] : null;
        }

        private static async Task Pump(NetworkStream from, NetworkStream to, Socket destination, TcpClient first, TcpClient second)
        {
            try
            {
                await from.CopyToAsync(to).ConfigureAwait(false);
                // Preserve TCP half-close so the reverse direction can finish.
                try { destination.Shutdown(SocketShutdown.Send); } catch (SocketException) { }
            }
            catch
            {
                first.Close();
                second.Close();
                throw;
            }
        }

        private async Task Relay(TcpClient client)
        {
            TcpClient backend = null;
            string peerText = ((IPEndPoint)client.Client.RemoteEndPoint).Address.ToString();
            try
            {
                GatewayRoute route = FindRoute(((IPEndPoint)client.Client.RemoteEndPoint).Address);
                if (route == null)
                {
                    Log("REJECT " + peerText + " no unique seat assignment");
                    return;
                }
                backend = new TcpClient(AddressFamily.InterNetwork);
                lock (sync) active.Add(backend);
                var connection = backend.ConnectAsync(IPAddress.Parse(route.BackendAddress), route.BackendPort);
                if (await Task.WhenAny(connection, Task.Delay(3000)).ConfigureAwait(false) != connection)
                {
                    backend.Close();
                    throw new IOException("Backend connection timed out");
                }
                await connection.ConfigureAwait(false);
                client.NoDelay = backend.NoDelay = true;
                Log("ROUTE " + peerText + " -> " + route.SeatId + " " + route.BackendAddress + ":" + route.BackendPort);
                var clientStream = client.GetStream();
                var backendStream = backend.GetStream();
                await Task.WhenAll(Pump(clientStream, backendStream, backend.Client, client, backend), Pump(backendStream, clientStream, client.Client, client, backend)).ConfigureAwait(false);
                Log("CLOSED " + peerText + " seat=" + route.SeatId);
            }
            catch (Exception error)
            {
                Log("ERROR " + peerText + " " + error.GetType().Name + ": " + error.Message);
            }
            finally
            {
                client.Close();
                backend?.Close();
                lock (sync) { active.Remove(client); if (backend != null) active.Remove(backend); }
            }
        }

        public void Run()
        {
            if (config.Routes == null || config.Routes.Length != 2 || config.Routes.Select(r => r.SeatId).Distinct().Count() != 2)
                throw new InvalidOperationException("Two distinct seat routes are required.");
            var listener = new TcpListener(IPAddress.Parse(config.ListenAddress), config.ListenPort);
            var handlers = new List<Task>();
            listener.Start();
            try
            {
                Log("LISTEN " + config.ListenAddress + ":" + config.ListenPort);
                File.WriteAllText(config.ReadyFile, "ready");
                while (!File.Exists(config.StopFile))
                {
                    if (!listener.Pending()) { Thread.Sleep(50); continue; }
                    var client = listener.AcceptTcpClient();
                    lock (sync) active.Add(client);
                    handlers.Add(Relay(client));
                    handlers.RemoveAll(task => task.IsCompleted);
                }
            }
            finally
            {
                listener.Stop();
                lock (sync) foreach (var client in active.ToArray()) client.Close();
                Task.WaitAll(handlers.ToArray(), 5000);
                Log("STOPPED");
            }
        }
    }

    internal static class GatewayProgram
    {
        public static int Main(string[] args)
        {
            try
            {
                if (args.Length != 1) throw new ArgumentException("Supply the gateway configuration path.");
                new SignalingGateway(JsonConvert.DeserializeObject<GatewayConfiguration>(File.ReadAllText(args[0]))).Run();
                return 0;
            }
            catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        }
    }
}
