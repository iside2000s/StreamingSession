// Diagnostic host using the unmodified CloudXR 6.2.3 public C API.
// It never sets ActiveRuntime or controls processes other than itself.
#include <windows.h>
#pragma warning(push)
#pragma warning(disable : 4201) // Anonymous event union in the NVIDIA SDK header.
#include <cxrServiceAPI.h>
#pragma warning(pop)
#include <NvStreamManagerClient.h>
#include <openxr/openxr.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <openxr/openxr_platform.h>
#include <chrono>
#include <filesystem>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;
using Options = std::map<std::wstring, std::wstring>;
using Microsoft::WRL::ComPtr;

static void Marker(const std::string& value)
{
    std::cout << "PROBE " << value << std::endl;
}

static std::wstring Required(const Options& options, const wchar_t* key)
{
    const auto found = options.find(key);
    if (found == options.end() || found->second.empty())
        throw std::runtime_error("Missing required argument");
    return found->second;
}

template <typename T>
static T Symbol(HMODULE module, const char* name)
{
    const auto address = GetProcAddress(module, name);
    if (!address)
        throw std::runtime_error(std::string("Missing SDK export: ") + name);
    // FARPROC and the typed function pointer have the same ABI representation.
    T function;
    static_assert(sizeof(function) == sizeof(address));
    memcpy(&function, &address, sizeof(function));
    return function;
}

static HMODULE Load(const fs::path& path)
{
    HMODULE module = LoadLibraryExW(path.c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!module)
        throw std::runtime_error("LoadLibraryExW failed, win32=" + std::to_string(GetLastError()));
    return module;
}

static void SetEnvironment(const wchar_t* key, const std::wstring& value)
{
    if (!SetEnvironmentVariableW(key, value.c_str()))
        throw std::runtime_error("Could not set child-process environment");
}

static std::string Utf8(const std::wstring& value)
{
    const int length = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (length <= 0) throw std::runtime_error("UTF-8 conversion failed");
    std::string encoded(static_cast<size_t>(length), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), encoded.data(), length, nullptr, nullptr);
    return encoded;
}

static int Manager(const Options& options, const fs::path& runtime)
{
    const fs::path directory = runtime.parent_path().parent_path();
    const auto managerPath = directory / L"NvStreamManager.exe";
    std::wstring command = L"\"" + managerPath.wstring() + L"\" --pipe \"" + Required(options, L"pipe") +
        L"\" --config \"" + Required(options, L"runtime-config") + L"\"";
    struct Job {
        HANDLE handle = nullptr;
        ~Job() { if (handle) CloseHandle(handle); }
    } job;
    job.handle = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job.handle || !SetInformationJobObject(job.handle, JobObjectExtendedLimitInformation, &limits, sizeof(limits)))
        throw std::runtime_error("Could not create an owned manager job");
    STARTUPINFOW startup{sizeof(STARTUPINFOW)};
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(managerPath.c_str(), command.data(), nullptr, nullptr, TRUE,
        CREATE_SUSPENDED | CREATE_NO_WINDOW, nullptr, directory.c_str(), &startup, &process))
        throw std::runtime_error("Could not launch the experimental manager");
    if (!AssignProcessToJobObject(job.handle, process.hProcess)) {
        TerminateProcess(process.hProcess, 1);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        throw std::runtime_error("Could not assign the experimental manager to its cleanup job");
    }
    ResumeThread(process.hThread);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);

    HMODULE module = Load(directory.parent_path() / L"NvStreamManagerClient.dll");
    const auto create = Symbol<pfn_nv_rpc_client_create>(module, "nv_rpc_client_create");
    const auto connect = Symbol<pfn_nv_rpc_client_connect>(module, "nv_rpc_client_connect");
    const auto start = Symbol<pfn_nv_rpc_client_start_cxr_service>(module, "nv_rpc_client_start_cxr_service");
    const auto status = Symbol<pfn_nv_rpc_client_get_cxr_service_status>(module, "nv_rpc_client_get_cxr_service_status");
    const auto stop = Symbol<pfn_nv_rpc_client_stop_cxr_service>(module, "nv_rpc_client_stop_cxr_service");
    const auto destroy = Symbol<pfn_nv_rpc_client_destroy>(module, "nv_rpc_client_destroy");
    nv_rpc_client_t client = nullptr;
    const auto pipe = Utf8(Required(options, L"pipe"));
    if (create(pipe.c_str(), &client) != NV_RPC_SUCCESS)
        throw std::runtime_error("Could not create the manager RPC client");
    nv_rpc_result_t connected = NV_RPC_ERROR_CONNECTION_FAILED;
    for (int attempt = 0; attempt < 50; ++attempt) {
        connected = connect(client);
        if (connected == NV_RPC_SUCCESS) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    Marker("MANAGER_CONNECT result=" + std::to_string(connected));
    if (connected != NV_RPC_SUCCESS) { destroy(client); return 30; }
    const std::string version = "6.2.3";
    const auto started = start(client, version.c_str(), version.size());
    Marker("START result=" + std::to_string(started));
    if (started != NV_RPC_SUCCESS) { destroy(client); return 31; }
    Marker("READY");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(std::stoi(Required(options, L"seconds")));
    bool appWasConnected = false;
    while (std::chrono::steady_clock::now() < deadline && !fs::exists(Required(options, L"stop-file"))) {
        nv_service_status_t current{};
        const auto queried = status(client, &current);
        if (queried != NV_RPC_SUCCESS || !current.openxr_runtime_running)
            throw std::runtime_error("Experimental manager lost its runtime");
        if (current.openxr_app_connected != appWasConnected) {
            Marker(current.openxr_app_connected ? "EVENT type=3" : "EVENT type=4");
            appWasConnected = current.openxr_app_connected;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    Marker("STOP result=" + std::to_string(stop(client)));
    destroy(client);
    Marker("STOPPED");
    return 0;
}

template <typename T>
static T XrFunction(PFN_xrGetInstanceProcAddr getProc, XrInstance instance, const char* name)
{
    PFN_xrVoidFunction address = nullptr;
    if (XR_FAILED(getProc(instance, name, &address)) || !address)
        throw std::runtime_error(std::string("Missing OpenXR function: ") + name);
    return reinterpret_cast<T>(address);
}

static void CheckXr(XrResult result, const char* operation)
{
    Marker(std::string(operation) + " result=" + std::to_string(result));
    if (XR_FAILED(result))
        throw std::runtime_error(std::string(operation) + " failed");
}

static void CheckGraphics(HRESULT result, const char* operation)
{
    if (FAILED(result))
        throw std::runtime_error(std::string(operation) + " failed: " + std::to_string(result));
}

static void GraphicsSession(const Options& options, PFN_xrGetInstanceProcAddr getProc,
    XrInstance instance, XrSystemId system)
{
    const auto requirementsFunction = XrFunction<PFN_xrGetD3D11GraphicsRequirementsKHR>(
        getProc, instance, "xrGetD3D11GraphicsRequirementsKHR");
    XrGraphicsRequirementsD3D11KHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR};
    CheckXr(requirementsFunction(instance, system, &requirements), "XR_D3D11_REQUIREMENTS");

    ComPtr<IDXGIFactory1> factory;
    CheckGraphics(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "CreateDXGIFactory1");
    ComPtr<IDXGIAdapter1> selectedAdapter;
    for (UINT index = 0;; ++index) {
        ComPtr<IDXGIAdapter1> adapter;
        const auto enumeration = factory->EnumAdapters1(index, &adapter);
        if (enumeration == DXGI_ERROR_NOT_FOUND)
            break;
        CheckGraphics(enumeration, "EnumAdapters1");
        DXGI_ADAPTER_DESC1 description{};
        CheckGraphics(adapter->GetDesc1(&description), "GetDesc1");
        if (memcmp(&description.AdapterLuid, &requirements.adapterLuid, sizeof(LUID)) == 0) {
            selectedAdapter = adapter;
            break;
        }
    }
    if (!selectedAdapter)
        throw std::runtime_error("The OpenXR graphics adapter was not found");
    const D3D_FEATURE_LEVEL featureLevels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    D3D_FEATURE_LEVEL selectedLevel{};
    CheckGraphics(D3D11CreateDevice(selectedAdapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, featureLevels, ARRAYSIZE(featureLevels), D3D11_SDK_VERSION,
        &device, &selectedLevel, &context), "D3D11CreateDevice");
    if (selectedLevel < requirements.minFeatureLevel)
        throw std::runtime_error("D3D11 feature level is too low for the runtime");

    struct Resources {
        XrSession session = XR_NULL_HANDLE;
        std::vector<XrSwapchain> swapchains;
        PFN_xrDestroySession destroySession;
        PFN_xrDestroySwapchain destroySwapchain;
        ~Resources() {
            for (auto swapchain : swapchains) destroySwapchain(swapchain);
            if (session != XR_NULL_HANDLE) destroySession(session);
        }
    } resources{XR_NULL_HANDLE, {},
        XrFunction<PFN_xrDestroySession>(getProc, instance, "xrDestroySession"),
        XrFunction<PFN_xrDestroySwapchain>(getProc, instance, "xrDestroySwapchain")};
    XrGraphicsBindingD3D11KHR binding{XR_TYPE_GRAPHICS_BINDING_D3D11_KHR};
    binding.device = device.Get();
    XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO};
    sessionInfo.next = &binding;
    sessionInfo.systemId = system;
    CheckXr(XrFunction<PFN_xrCreateSession>(getProc, instance, "xrCreateSession")(
        instance, &sessionInfo, &resources.session), "XR_CREATE_SESSION");

    const auto enumerateFormats = XrFunction<PFN_xrEnumerateSwapchainFormats>(getProc, instance, "xrEnumerateSwapchainFormats");
    uint32_t count = 0;
    CheckXr(enumerateFormats(resources.session, 0, &count, nullptr), "XR_ENUMERATE_FORMAT_COUNT");
    if (count == 0) throw std::runtime_error("Runtime reported no swapchain formats");
    std::vector<int64_t> formats(count);
    CheckXr(enumerateFormats(resources.session, count, &count, formats.data()), "XR_ENUMERATE_FORMATS");
    const auto createSwapchain = XrFunction<PFN_xrCreateSwapchain>(getProc, instance, "xrCreateSwapchain");
    for (int eye = 0; eye < 2; ++eye) {
        XrSwapchainCreateInfo swapchainInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO};
        swapchainInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
        swapchainInfo.format = formats.front();
        swapchainInfo.sampleCount = 1;
        swapchainInfo.width = 256;
        swapchainInfo.height = 256;
        swapchainInfo.faceCount = 1;
        swapchainInfo.arraySize = 1;
        swapchainInfo.mipCount = 1;
        XrSwapchain swapchain = XR_NULL_HANDLE;
        CheckXr(createSwapchain(resources.session, &swapchainInfo, &swapchain), "XR_CREATE_SWAPCHAIN");
        resources.swapchains.push_back(swapchain);
    }
    Marker("XR_SWAPCHAINS_READY count=2");
    // No xrBeginSession/xrEndFrame: this verifies independent GPU resources,
    // not headset video delivery or rendering performance.
    Marker("XR_GRAPHICS_HOLD_BEGIN");
    std::this_thread::sleep_for(std::chrono::seconds(std::stoi(Required(options, L"hold-seconds"))));
    Marker("XR_GRAPHICS_HOLD_END");
}

// Query only documented network properties through the public API. This does
// not start a runtime, bind a port, or establish a headset connection.
static int NetworkProperties(const Options& options, const fs::path& runtime)
{
    HMODULE module = Load(runtime / L"cloudxr.dll");
    auto create = Symbol<PFN_nv_cxr_service_create>(module, "nv_cxr_service_create");
    auto destroy = Symbol<PFN_nv_cxr_service_destroy>(module, "nv_cxr_service_destroy");
    auto setString = Symbol<PFN_nv_cxr_service_set_string_property>(module, "nv_cxr_service_set_string_property");
    auto setInteger = Symbol<PFN_nv_cxr_service_set_int64_property>(module, "nv_cxr_service_set_int64_property");
    auto setBoolean = Symbol<PFN_nv_cxr_service_set_boolean_property>(module, "nv_cxr_service_set_boolean_property");
    auto getInteger = Symbol<PFN_nv_cxr_service_get_int64_property>(module, "nv_cxr_service_get_int64_property");
    auto getBoolean = Symbol<PFN_nv_cxr_service_get_boolean_property>(module, "nv_cxr_service_get_boolean_property");
    nv_cxr_service* service = nullptr;
    if (create(&service) != NV_CXR_SUCCESS) throw std::runtime_error("Could not create property probe service");
    const auto check = [](nv_cxr_result_t result, const char* name) {
        if (result != NV_CXR_SUCCESS) throw std::runtime_error(std::string("Property operation failed: ") + name + " result=" + std::to_string(result));
    };
    try {
        const auto profileOption = options.find(L"profile");
        const std::string profile = profileOption == options.end() ? "apple-vision-pro" : Utf8(profileOption->second);
        check(setString(service, "device-profile", strlen("device-profile"), profile.c_str(), profile.size()), "device-profile");
        bool ice = false;
        int64_t media = -1;
        check(getBoolean(service, "enable-ice", strlen("enable-ice"), &ice), "get enable-ice");
        check(getInteger(service, "media-port", strlen("media-port"), &media), "get media-port");
        Marker("NETWORK_DEFAULT enable-ice=" + std::to_string(ice) + " media-port=" + std::to_string(media));
        const auto iceOption = Required(options, L"enable-ice");
        if (iceOption != L"true" && iceOption != L"false") throw std::runtime_error("enable-ice must be true or false");
        const bool requestedIce = iceOption == L"true";
        const int64_t requestedMedia = std::stoll(Required(options, L"media-port"));
        check(setBoolean(service, "enable-ice", strlen("enable-ice"), requestedIce), "set enable-ice");
        check(setInteger(service, "media-port", strlen("media-port"), requestedMedia), "set media-port");
        check(getBoolean(service, "enable-ice", strlen("enable-ice"), &ice), "read enable-ice");
        check(getInteger(service, "media-port", strlen("media-port"), &media), "read media-port");
        if (ice != requestedIce || media != requestedMedia) throw std::runtime_error("Network property readback mismatch");
        Marker("NETWORK_READBACK enable-ice=" + std::to_string(ice) + " media-port=" + std::to_string(media));
        Marker("NO_SERVICE_START property acceptance is not a media transport test");
    }
    catch (...) { destroy(service); throw; }
    destroy(service);
    return 0;
}

static int Service(const Options& options, const fs::path& runtime)
{
    SetEnvironment(L"NV_CXR_OUTPUT_DIR", Required(options, L"log-dir"));
    SetEnvironment(L"NV_CXR_FILE_LOGGING", L"true");
    HMODULE module = Load(runtime / L"cloudxr.dll");
    auto create = Symbol<PFN_nv_cxr_service_create>(module, "nv_cxr_service_create");
    auto setString = Symbol<PFN_nv_cxr_service_set_string_property>(module, "nv_cxr_service_set_string_property");
    auto setInteger = Symbol<PFN_nv_cxr_service_set_int64_property>(module, "nv_cxr_service_set_int64_property");
    auto setBoolean = Symbol<PFN_nv_cxr_service_set_boolean_property>(module, "nv_cxr_service_set_boolean_property");
    auto start = Symbol<PFN_nv_cxr_service_start>(module, "nv_cxr_service_start");
    auto stop = Symbol<PFN_nv_cxr_service_stop>(module, "nv_cxr_service_stop");
    auto join = Symbol<PFN_nv_cxr_service_join>(module, "nv_cxr_service_join");
    auto destroy = Symbol<PFN_nv_cxr_service_destroy>(module, "nv_cxr_service_destroy");
    auto poll = Symbol<PFN_nv_cxr_service_poll_event>(module, "nv_cxr_service_poll_event");
    auto version = Symbol<PFN_nv_cxr_get_runtime_version>(module, "nv_cxr_get_runtime_version");
    uint32_t major = 0, minor = 0, patch = 0;
    version(&major, &minor, &patch);
    Marker("VERSION " + std::to_string(major) + "." + std::to_string(minor) + "." + std::to_string(patch));

    nv_cxr_service* service = nullptr;
    const auto created = create(&service);
    Marker("CREATE result=" + std::to_string(created));
    if (created != NV_CXR_SUCCESS)
        return 10;

    const auto check = [](nv_cxr_result_t result, const char* property) {
        Marker(std::string("PROPERTY ") + property + " result=" + std::to_string(result));
        if (result != NV_CXR_SUCCESS)
            throw std::runtime_error(std::string("SDK rejected property: ") + property);
    };
    try {
        const auto profileOption = options.find(L"profile");
        const std::string profile = profileOption == options.end() ? "apple-vision-pro" : Utf8(profileOption->second);
        check(setString(service, "device-profile", strlen("device-profile"), profile.c_str(), profile.size()), "device-profile");
        const char* endpoint = "127.0.0.1";
        check(setString(service, "endpoint-ip", strlen("endpoint-ip"), endpoint, strlen(endpoint)), "endpoint-ip");
        check(setInteger(service, "server-port", strlen("server-port"), std::stoll(Required(options, L"port"))), "server-port");
        check(setInteger(service, "media-port", strlen("media-port"), std::stoll(Required(options, L"media-port"))), "media-port");
        const auto iceOption = options.find(L"enable-ice");
        if (iceOption != options.end()) {
            if (iceOption->second != L"true" && iceOption->second != L"false") throw std::runtime_error("enable-ice must be true or false");
            check(setBoolean(service, "enable-ice", strlen("enable-ice"), iceOption->second == L"true"), "enable-ice");
        }
        check(setBoolean(service, "audio-streaming", strlen("audio-streaming"), false), "audio-streaming");
        check(setBoolean(service, "mic-streaming", strlen("mic-streaming"), false), "mic-streaming");
        check(setBoolean(service, "runtime-foveation", strlen("runtime-foveation"), false), "runtime-foveation");
    }
    catch (...) {
        destroy(service);
        throw;
    }

    Marker("STARTING");
    const auto started = start(service);
    Marker("START result=" + std::to_string(started));
    if (started != NV_CXR_SUCCESS) {
        // Failed startup may leave internal SDK threads in an undocumented state.
        // Exit only this disposable host; the OS reclaims its resources.
        return 11;
    }
    Marker("READY");
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::seconds(std::stoi(Required(options, L"seconds")));
    const fs::path stopFile = Required(options, L"stop-file");
    while (std::chrono::steady_clock::now() < deadline && !fs::exists(stopFile)) {
        nv_cxr_event_t event{};
        const auto result = poll(service, &event);
        if (result == NV_CXR_SUCCESS && event.type != NV_CXR_EVENT_NONE)
            Marker("EVENT type=" + std::to_string(event.type));
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    Marker("STOP result=" + std::to_string(stop(service)));
    Marker("JOIN result=" + std::to_string(join(service)));
    destroy(service);
    Marker("STOPPED");
    return 0;
}

static int Client(const Options& options, const fs::path& runtime)
{
    // Per-process loader selection; the machine-wide registry is untouched.
    SetEnvironment(L"XR_RUNTIME_JSON", (runtime / L"openxr_cloudxr.json").wstring());
    HMODULE loader = Load(Required(options, L"loader"));
    auto getProc = Symbol<PFN_xrGetInstanceProcAddr>(loader, "xrGetInstanceProcAddr");
    PFN_xrVoidFunction address = nullptr;
    XrResult result = getProc(XR_NULL_HANDLE, "xrCreateInstance", &address);
    if (XR_FAILED(result)) {
        Marker("GET_CREATE_INSTANCE result=" + std::to_string(result));
        return 20;
    }
    auto createInstance = reinterpret_cast<PFN_xrCreateInstance>(address);
    XrInstanceCreateInfo info{XR_TYPE_INSTANCE_CREATE_INFO};
    strcpy_s(info.applicationInfo.applicationName, "CloudXR MultiInstance Probe");
    info.applicationInfo.applicationVersion = 1;
    info.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 6);
    const bool graphics = options.count(L"graphics") != 0 && Required(options, L"graphics") == L"true";
    const char* extension = XR_KHR_D3D11_ENABLE_EXTENSION_NAME;
    if (graphics) {
        info.enabledExtensionCount = 1;
        info.enabledExtensionNames = &extension;
    }
    XrInstance instance = XR_NULL_HANDLE;
    result = createInstance(&info, &instance);
    Marker("XR_CREATE_INSTANCE result=" + std::to_string(result));
    if (XR_FAILED(result))
        return 21;

    getProc(instance, "xrDestroyInstance", &address);
    auto destroyInstance = reinterpret_cast<PFN_xrDestroyInstance>(address);
    getProc(instance, "xrGetSystem", &address);
    auto getSystem = reinterpret_cast<PFN_xrGetSystem>(address);
    XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO};
    systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XrSystemId system = XR_NULL_SYSTEM_ID;
    result = getSystem(instance, &systemInfo, &system);
    Marker("XR_GET_SYSTEM result=" + std::to_string(result));
    if (XR_SUCCEEDED(result)) {
        getProc(instance, "xrGetSystemProperties", &address);
        auto getProperties = reinterpret_cast<PFN_xrGetSystemProperties>(address);
        XrSystemProperties properties{XR_TYPE_SYSTEM_PROPERTIES};
        const auto propertiesResult = getProperties(instance, system, &properties);
        Marker("XR_SYSTEM_PROPERTIES result=" + std::to_string(propertiesResult) + " name=" + properties.systemName);
        if (graphics) GraphicsSession(options, getProc, instance, system);
    }
    std::this_thread::sleep_for(std::chrono::seconds(1));
    Marker("XR_DESTROY_INSTANCE result=" + std::to_string(destroyInstance(instance)));
    return XR_SUCCEEDED(result) ? 0 : 22;
}

int wmain(int argc, wchar_t** argv)
{
    try {
        Options options;
        for (int index = 1; index < argc; index += 2) {
            if (index + 1 >= argc || std::wstring(argv[index]).rfind(L"--", 0) != 0)
                throw std::runtime_error("Arguments must be --name value pairs");
            const auto inserted = options.emplace(std::wstring(argv[index] + 2), argv[index + 1]);
            if (!inserted.second)
                throw std::runtime_error("Duplicate argument");
        }
        const fs::path runtime = fs::canonical(Required(options, L"runtime"));
        const auto temp = options.find(L"temp-dir");
        if (temp != options.end()) {
            const auto directory = fs::canonical(temp->second).wstring();
            SetEnvironment(L"TMP", directory);
            SetEnvironment(L"TEMP", directory);
        }
        const auto mode = Required(options, L"mode");
        if (mode == L"network-properties")
            return NetworkProperties(options, runtime);
        if (mode == L"service")
            return Service(options, runtime);
        if (mode == L"manager")
            return Manager(options, runtime);
        if (mode == L"client")
            return Client(options, runtime);
        throw std::runtime_error("Mode must be service, manager, client or network-properties");
    }
    catch (const std::exception& error) {
        Marker(std::string("ERROR ") + error.what());
        return 1;
    }
}
