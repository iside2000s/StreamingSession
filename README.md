# StreamingSession: Streaming immersive content from a CloudXR™ application to visionOS and iOS

## Overview

This repository contains the supplementary materials necessary to support a streaming session, allowing you to connect, pair, and stream an OpenXR experience to a visionOS or iOS device. Use the StreamingSession-WindowsApp and StreamingSession-OpenXRSample applications to create a streaming endpoint on your Windows computer that visionOS and iOS devices can stream content from.

On visionOS, you can leverage the [Foveated Streaming](https://developer.apple.com/documentation/foveatedstreaming) framework to stream high quality OpenXR applications.
The endpoint streams high quality content only where necessary based on information about the approximate region where the person is looking, ensuring performance. 

On iOS, you can leverage [StreamingSession.xcframework](./StreamingSession.xcframework) to stream an OpenXR experience to an iOS device. StreamingSession.xcframework has a similar API to FoveatedStreaming.framework on visionOS, allowing you to easily build cross-platform streaming applications.

## Prerequisites

- A Windows computer with Visual Studio 2022 (or later) installed is required to build and test this project.
- The [NVIDIA CloudXR SDK](https://catalog.ngc.nvidia.com/orgs/nvidia/collections/cloudxr-sdk) is required to stream the OpenXR application.
- An Apple Vision Pro or iOS device is required to receive the streamed content.

## Setup Instructions

- Download and build `StreamingSession-WindowsApp`. See the [README](./StreamingSession-WindowsApp/README.md) for instructions.
- Download and build `StreamingSession-OpenXRSample`. See the [README](./StreamingSession-OpenXRSample/README.md) for instructions.
- Create an app that streams content from a computer by using the multi-platform Foveated Streaming App template in Xcode, or—for Apple Vision Pro—download the [Creating a foveated streaming client on visionOS](https://developer.apple.com/documentation/foveatedstreaming/creating-a-foveated-streaming-client-on-visionos) sample.
- Ensure both the computer and the device with the client app are connected to the same network.

## How it Works

- When `StreamingSession-WindowsApp` is run, it broadcasts an mDNS service to permit discovery by visionOS/iOS.
- When the visionOS/iOS device initiates a connection to the computer, a series of messages is sent between the device and the computer via a TCP connection. For more information on the content and format of the messages, see [Establishing foveated streaming sessions with Apple Vision Pro](https://developer.apple.com/documentation/foveatedstreaming/establishing-foveated-streaming-sessions-with-apple-vision-pro).
- After receiving the `RequestBarcodePresentation` message from the visionOS/iOS device, `StreamingSession-WindowsApp` displays a QR code containing the client token and certificate fingerprint.
- The visionOS/iOS device authenticates the connection by scanning the QR code. 
- `StreamingSession-WindowsApp` launches the CloudXR server and sends the `MediaStreamIsReady` message to notify the visionOS/iOS device that it’s ready to stream content.
- `StreamingSession-OpenXRSample` displays VR content which CloudXR streams to the visionOS/iOS device.

## Example Flow

### visionOS

- Run the multi-platform Foveated Streaming App template on a visionOS device.
- Run `StreamingSession-WindowsApp` on the computer. This advertises the computer as discoverable streaming endpoint, allowing Apple Vision Pro to initiate a connection.
- Connect to the computer using the Foveated Streaming framework.
- Run `StreamingSession-OpenXRSample` on the computer.
- Apple Vision Pro streams the OpenXR application from the computer with foveation, displaying an animated 3D cube in an immersive space.

### iOS

- Run the multi-platform Foveated Streaming App template on an iOS device.
- Run `StreamingSession-WindowsApp` on the computer. This advertises the computer as discoverable streaming endpoint, allowing the iOS device to initiate a connection.
- Connect to the computer using the Streaming Session framework.
- Run `StreamingSession-OpenXRSample` on the computer.
- The iOS device streams the OpenXR application from the computer, displaying an animated 3D cube.

## Experimental multi-instance investigation

The [Windows multi-instance probe](experiments/cloudxr-multi-instance/README.md) tests separate per-process temporary directories, runtime ports, and Stream Manager RPC endpoints. It has demonstrated concurrent OpenXR/D3D11 resource creation on the tested machine; dual-headset video streaming and multiplayer interactions are not yet implemented. See the [measured results](experiments/cloudxr-multi-instance/RESULTS.md).

The subsequent [headset experiment](experiments/cloudxr-headset-test/README.md) adds two independent pairing windows and a source-IP signaling relay for existing visionOS clients. Actual headset testing found a native UDP media-port conflict when connecting both seats; it does **not** provide simultaneous dual-headset streaming. See the [headset results](experiments/cloudxr-headset-test/RESULTS.md).

## Further Reading

- [Foveated Streaming](https://developer.apple.com/documentation/foveatedstreaming)
- [Streaming a CloudXR application to Apple Vision Pro with foveation](https://developer.apple.com/documentation/foveatedstreaming/streaming-a-cloudxr-application-to-apple-vision-pro-with-foveation)
- [Establishing foveated streaming sessions with Apple Vision Pro](https://developer.apple.com/documentation/foveatedstreaming/establishing-foveated-streaming-sessions-with-apple-vision-pro)
- [Creating a foveated streaming client on visionOS](https://developer.apple.com/documentation/foveatedstreaming/creating-a-foveated-streaming-client-on-visionos)
- [NVIDIA CloudXR SDK](https://docs.nvidia.com/cloudxr-sdk)
