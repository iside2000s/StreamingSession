// This software contains source code provided by NVIDIA Corporation.
// Uses the public NVENC API header without modifying any GPU driver or SDK DLL.
#include <winsock2.h>
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#pragma warning(push)
#pragma warning(disable : 4201) // Anonymous unions in the public NVENC header.
#include <nvEncodeAPI.h>
#pragma warning(pop)
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

struct BoundPorts
{
    bool started = false;
    std::vector<SOCKET> sockets;
    ~BoundPorts() { for (auto socket : sockets) closesocket(socket); if (started) WSACleanup(); }
    void Bind()
    {
        WSADATA data{};
        if (WSAStartup(MAKEWORD(2, 2), &data)) throw std::runtime_error("WSAStartup failed");
        started = true;
        for (const int port : {47998, 47999}) {
            SOCKET socket = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
            if (socket == INVALID_SOCKET) throw std::runtime_error("UDP socket creation failed");
            sockets.push_back(socket);
            const BOOL exclusive = TRUE;
            if (setsockopt(socket, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusive), sizeof(exclusive)))
                throw std::runtime_error("Could not set exclusive UDP binding");
            sockaddr_in address{};
            address.sin_family = AF_INET;
            address.sin_port = htons(static_cast<u_short>(port));
            address.sin_addr.s_addr = htonl(INADDR_ANY);
            if (bind(socket, reinterpret_cast<const sockaddr*>(&address), sizeof(address)))
                throw std::runtime_error("UDP binding failed for port " + std::to_string(port) + " error=" + std::to_string(WSAGetLastError()));
        }
        std::cout << "PASS UDP_NAMESPACE_BOUND ports=47998,47999" << std::endl;
    }
};

static void Check(NVENCSTATUS status, const char* operation)
{
    if (status != NV_ENC_SUCCESS)
        throw std::runtime_error(std::string(operation) + " NVENC status=" + std::to_string(status));
}

struct Encoder
{
    NV_ENCODE_API_FUNCTION_LIST api{};
    void* session = nullptr;
    NV_ENC_REGISTERED_PTR resource = nullptr;
    NV_ENC_INPUT_PTR input = nullptr;
    NV_ENC_OUTPUT_PTR output = nullptr;
    ~Encoder()
    {
        if (!session) return;
        if (input) api.nvEncUnmapInputResource(session, input);
        if (resource) api.nvEncUnregisterResource(session, resource);
        if (output) api.nvEncDestroyBitstreamBuffer(session, output);
        api.nvEncDestroyEncoder(session);
    }
};

int main(int argc, char** argv)
{
    try {
        BoundPorts boundPorts;
        if (argc == 2 && std::string(argv[1]) == "--bind-udp") boundPorts.Bind();
        else if (argc != 1) throw std::runtime_error("Only the optional --bind-udp argument is supported");
        ComPtr<IDXGIFactory1> factory;
        if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) throw std::runtime_error("CreateDXGIFactory1 failed");
        ComPtr<IDXGIAdapter1> adapter;
        for (UINT index = 0; ; ++index) {
            ComPtr<IDXGIAdapter1> candidate;
            if (factory->EnumAdapters1(index, &candidate) == DXGI_ERROR_NOT_FOUND) break;
            DXGI_ADAPTER_DESC1 description{};
            if (FAILED(candidate->GetDesc1(&description))) continue;
            if (description.VendorId == 0x10de && !(description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) {
                adapter = candidate;
                std::wcout << L"GPU " << description.Description << std::endl;
                break;
            }
        }
        if (!adapter) throw std::runtime_error("No NVIDIA DXGI hardware adapter is available");
        ComPtr<ID3D11Device> device;
        ComPtr<ID3D11DeviceContext> context;
        if (FAILED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context)))
            throw std::runtime_error("D3D11 device creation failed");

        HMODULE library = LoadLibraryExW(L"nvEncodeAPI64.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!library) throw std::runtime_error("System NVIDIA encode driver is unavailable, win32=" + std::to_string(GetLastError()));
        FARPROC address = GetProcAddress(library, "NvEncodeAPICreateInstance");
        if (!address) throw std::runtime_error("NvEncodeAPICreateInstance is unavailable");
        using CreateInstance = NVENCSTATUS(NVENCAPI*)(NV_ENCODE_API_FUNCTION_LIST*);
        CreateInstance create = nullptr;
        static_assert(sizeof(create) == sizeof(address));
        std::memcpy(&create, &address, sizeof(create));
        ComPtr<ID3D11Texture2D> texture; // Must outlive the encoder registration.
        Encoder encoder;
        encoder.api.version = NV_ENCODE_API_FUNCTION_LIST_VER;
        Check(create(&encoder.api), "NvEncodeAPICreateInstance");
        NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS open{};
        open.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
        open.device = device.Get();
        open.deviceType = NV_ENC_DEVICE_TYPE_DIRECTX;
        open.apiVersion = NVENCAPI_VERSION;
        Check(encoder.api.nvEncOpenEncodeSessionEx(&open, &encoder.session), "OpenEncodeSessionEx");

        NV_ENC_PRESET_CONFIG preset{};
        preset.version = NV_ENC_PRESET_CONFIG_VER;
        preset.presetCfg.version = NV_ENC_CONFIG_VER;
        Check(encoder.api.nvEncGetEncodePresetConfigEx(encoder.session, NV_ENC_CODEC_H264_GUID,
            NV_ENC_PRESET_P3_GUID, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &preset), "GetEncodePresetConfigEx");
        preset.presetCfg.gopLength = 1;
        preset.presetCfg.frameIntervalP = 1;
        preset.presetCfg.rcParams.enableLookahead = 0;
        preset.presetCfg.rcParams.rateControlMode = NV_ENC_PARAMS_RC_CONSTQP;
        preset.presetCfg.rcParams.constQP = {28, 28, 28};
        NV_ENC_INITIALIZE_PARAMS initialize{};
        initialize.version = NV_ENC_INITIALIZE_PARAMS_VER;
        initialize.encodeGUID = NV_ENC_CODEC_H264_GUID;
        initialize.presetGUID = NV_ENC_PRESET_P3_GUID;
        initialize.tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
        initialize.encodeWidth = initialize.darWidth = initialize.maxEncodeWidth = 256;
        initialize.encodeHeight = initialize.darHeight = initialize.maxEncodeHeight = 256;
        initialize.frameRateNum = 30;
        initialize.frameRateDen = 1;
        initialize.enablePTD = 1;
        initialize.encodeConfig = &preset.presetCfg;
        Check(encoder.api.nvEncInitializeEncoder(encoder.session, &initialize), "InitializeEncoder");

        D3D11_TEXTURE2D_DESC textureDescription{};
        textureDescription.Width = textureDescription.Height = 256;
        textureDescription.MipLevels = textureDescription.ArraySize = textureDescription.SampleDesc.Count = 1;
        textureDescription.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        textureDescription.Usage = D3D11_USAGE_DEFAULT;
        textureDescription.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        std::vector<uint32_t> pixels(256 * 256, 0xff406080u);
        D3D11_SUBRESOURCE_DATA data{pixels.data(), 256 * 4, 0};
        if (FAILED(device->CreateTexture2D(&textureDescription, &data, &texture)))
            throw std::runtime_error("D3D11 input texture creation failed");
        NV_ENC_REGISTER_RESOURCE registration{};
        registration.version = NV_ENC_REGISTER_RESOURCE_VER;
        registration.resourceType = NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX;
        registration.resourceToRegister = texture.Get();
        registration.width = registration.height = 256;
        registration.bufferFormat = NV_ENC_BUFFER_FORMAT_ARGB;
        registration.bufferUsage = NV_ENC_INPUT_IMAGE;
        Check(encoder.api.nvEncRegisterResource(encoder.session, &registration), "RegisterResource");
        encoder.resource = registration.registeredResource;
        NV_ENC_MAP_INPUT_RESOURCE mapping{};
        mapping.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
        mapping.registeredResource = encoder.resource;
        Check(encoder.api.nvEncMapInputResource(encoder.session, &mapping), "MapInputResource");
        encoder.input = mapping.mappedResource;
        NV_ENC_CREATE_BITSTREAM_BUFFER output{};
        output.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
        Check(encoder.api.nvEncCreateBitstreamBuffer(encoder.session, &output), "CreateBitstreamBuffer");
        encoder.output = output.bitstreamBuffer;
        NV_ENC_PIC_PARAMS picture{};
        picture.version = NV_ENC_PIC_PARAMS_VER;
        picture.inputBuffer = encoder.input;
        picture.bufferFmt = mapping.mappedBufferFmt;
        picture.inputWidth = picture.inputHeight = 256;
        picture.outputBitstream = encoder.output;
        picture.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
        picture.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS;
        Check(encoder.api.nvEncEncodePicture(encoder.session, &picture), "EncodePicture");
        NV_ENC_LOCK_BITSTREAM lock{};
        lock.version = NV_ENC_LOCK_BITSTREAM_VER;
        lock.outputBitstream = encoder.output;
        Check(encoder.api.nvEncLockBitstream(encoder.session, &lock), "LockBitstream");
        const uint32_t size = lock.bitstreamSizeInBytes;
        Check(encoder.api.nvEncUnlockBitstream(encoder.session, encoder.output), "UnlockBitstream");
        if (size == 0) throw std::runtime_error("Encoder returned no bytes");
        std::cout << "PASS D3D11_NVENC_H264 width=256 height=256 encoded_bytes=" << size << std::endl;
        return 0;
    }
    catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << std::endl;
        return 1;
    }
}
