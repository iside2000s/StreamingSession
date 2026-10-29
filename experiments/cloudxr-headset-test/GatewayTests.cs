using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;

namespace StreamingSessionExperiments
{
    internal static class GatewayTests
    {
        private static byte[] Exchange(int port, string source, byte[] payload)
        {
            using (var client = new TcpClient(AddressFamily.InterNetwork))
            {
                client.Client.Bind(new IPEndPoint(IPAddress.Parse(source), 0));
                client.Connect(IPAddress.Loopback, port);
                client.ReceiveTimeout = 3000;
                var stream = client.GetStream();
                stream.Write(payload, 0, payload.Length);
                client.Client.Shutdown(SocketShutdown.Send);
                using (var received = new MemoryStream())
                {
                    stream.CopyTo(received);
                    return received.ToArray();
                }
            }
        }

        private static Task Echo(TcpListener listener, byte tag)
        {
            return Task.Run(() =>
            {
                using (var client = listener.AcceptTcpClient())
                using (var bytes = new MemoryStream())
                {
                    client.ReceiveTimeout = 3000;
                    var stream = client.GetStream();
                    stream.CopyTo(bytes);
                    var payload = bytes.ToArray();
                    stream.WriteByte(tag);
                    stream.Write(payload, 0, payload.Length);
                }
            });
        }

        public static int Main(string[] args)
        {
            string directory = Path.GetFullPath(args[0]);
            Directory.CreateDirectory(directory);
            var a = new TcpListener(IPAddress.Loopback, 0);
            var b = new TcpListener(IPAddress.Loopback, 0);
            a.Start(); b.Start();
            var portProbe = new TcpListener(IPAddress.Loopback, 0);
            portProbe.Start();
            int gatewayPort = ((IPEndPoint)portProbe.LocalEndpoint).Port;
            portProbe.Stop();
            var config = new GatewayConfiguration
            {
                ListenAddress = "127.0.0.1", ListenPort = gatewayPort,
                StopFile = Path.Combine(directory, "stop"), ReadyFile = Path.Combine(directory, "ready"), LogFile = Path.Combine(directory, "gateway.log"),
                Routes = new[] {
                    new GatewayRoute {SeatId="a", BackendAddress="127.0.0.1", BackendPort=((IPEndPoint)a.LocalEndpoint).Port, ClientRoutePath=Path.Combine(directory,"a.json")},
                    new GatewayRoute {SeatId="b", BackendAddress="127.0.0.1", BackendPort=((IPEndPoint)b.LocalEndpoint).Port, ClientRoutePath=Path.Combine(directory,"b.json")}
                }
            };
            File.WriteAllText(config.Routes[0].ClientRoutePath, JsonConvert.SerializeObject(new ClientRoute {SeatId="a", ClientAddress="127.0.0.1"}));
            File.WriteAllText(config.Routes[1].ClientRoutePath, JsonConvert.SerializeObject(new ClientRoute {SeatId="b", ClientAddress="127.0.0.2"}));
            var gateway = Task.Run(() => new SignalingGateway(config).Run());
            try
            {
                var deadline = DateTime.UtcNow.AddSeconds(5);
                while (!File.Exists(config.ReadyFile) && DateTime.UtcNow < deadline) Thread.Sleep(20);
                if (!File.Exists(config.ReadyFile)) throw new Exception("Gateway did not start");
                byte[] payload = Enumerable.Range(0, 16384).Select(i => (byte)(i % 256)).ToArray();
                Task first = Echo(a, (byte)'A'), second = Echo(b, (byte)'B');
                var replyA = Exchange(gatewayPort, "127.0.0.1", payload);
                var replyB = Exchange(gatewayPort, "127.0.0.2", payload);
                if (replyA[0] != 'A' || !replyA.Skip(1).SequenceEqual(payload)) throw new Exception("A routing or byte relay failed");
                if (replyB[0] != 'B' || !replyB.Skip(1).SequenceEqual(payload)) throw new Exception("B routing or byte relay failed");
                Task.WaitAll(new[] {first, second}, 5000);
                if (Exchange(gatewayPort, "127.0.0.3", new byte[0]).Length != 0) throw new Exception("Unknown peer was not rejected");
                File.WriteAllText(config.Routes[1].ClientRoutePath, JsonConvert.SerializeObject(new ClientRoute {SeatId="b", ClientAddress="127.0.0.1"}));
                if (Exchange(gatewayPort, "127.0.0.1", new byte[0]).Length != 0) throw new Exception("Ambiguous peer was not rejected");
                Console.WriteLine("PASS: source-IP routing, binary relay, TCP half-close, unknown peer rejection, ambiguous peer rejection");
                return 0;
            }
            catch (Exception error) { Console.Error.WriteLine(error); return 1; }
            finally
            {
                File.WriteAllText(config.StopFile, "stop");
                a.Stop(); b.Stop();
                if (!gateway.Wait(5000)) throw new Exception("Gateway did not stop");
            }
        }
    }
}
