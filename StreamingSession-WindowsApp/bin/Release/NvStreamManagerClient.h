// SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES.
// All rights reserved. SPDX-License-Identifier: Apache-2.0 or MIT

#pragma once

#include <stddef.h> // For size_t
#include <stdint.h> // For uint32_t

#ifdef __cplusplus
extern "C" {
#endif

// DLL export/import macros for C interface
#ifdef NV_RPC_CLIENT_EXPORTS
#define NV_RPC_CLIENT_C_API __declspec(dllexport)
#elif defined(NV_RPC_CLIENT_DLL)
#define NV_RPC_CLIENT_C_API __declspec(dllimport)
#else
#define NV_RPC_CLIENT_C_API
#endif

// Opaque handle for the RPC client
typedef struct nv_rpc_client_handle *nv_rpc_client_t;

// Error codes
typedef enum
{
	NV_RPC_SUCCESS = 0,
	NV_RPC_ERROR_INVALID_HANDLE = -1,
	NV_RPC_ERROR_CONNECTION_FAILED = -2,
	NV_RPC_ERROR_RPC_CALL_FAILED = -3,
	NV_RPC_ERROR_INVALID_PARAMETER = -4,
	NV_RPC_ERROR_MEMORY_ALLOCATION = -5,
	NV_RPC_ERROR_CXR_STARTUP_FAILED = -6,
	NV_RPC_ERROR_CXR_PORT_UNAVAILABLE = -7,
	NV_RPC_ERROR_UNKNOWN = -999
} nv_rpc_result_t;

// Cryptographic algorithms for key fingerprinting
typedef enum
{
	NV_CRYPTO_ALG_MD5 = 0,
	NV_CRYPTO_ALG_SHA1 = 1,
	NV_CRYPTO_ALG_SHA256 = 2,
	NV_CRYPTO_ALG_SHA512 = 3
} nv_crypto_algorithm_t;

// Structure for returning string arrays
typedef struct
{
	char **strings;
	size_t count;
} nv_string_array_t;

// CloudXR Service Status Structure (explicit fields for public API)
typedef struct
{
	bool openxr_runtime_running;        // true if OpenXR runtime is running, false
	                                    // otherwise
	bool openxr_app_connected;          // true if OpenXR application is connected, false
	                                    // otherwise
	bool cloudxr_client_connected;      // true if CloudXR streaming client is
	                                    // connected, false otherwise
	char openxr_log_file_path[256];     // path to the OpenXR log file
	size_t openxr_log_file_path_length; // Length of openxr_log_file_path
	int reserved[4096];                 // Reserved for future use (must be zero)
	                                    // Future fields can be added here for new status information
} nv_service_status_t;

/**
 * @brief Create a new RPC client
 *
 * @param pipe_name The named pipe endpoint, can be nullptr for default
 * "cloudxr-runtime"
 * @param client_out Output parameter for the created client handle
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_create(const char *pipe_name, nv_rpc_client_t *client_out);

/**
 * @brief Destroy an RPC client and free resources
 *
 * @param client The client handle to destroy
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_destroy(nv_rpc_client_t client);

/**
 * @brief Connect to the RPC server
 *
 * @param client The client handle
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_connect(nv_rpc_client_t client);

/**
 * @brief Disconnect from the RPC server
 *
 * @param client The client handle
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_disconnect(nv_rpc_client_t client);

/**
 * @brief Start the CloudXR service with specified version
 *
 * @param client The client handle
 * @param service_version The version of CloudXR service to start
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_start_cxr_service(nv_rpc_client_t client, const char *service_version, size_t service_version_length);

/**
 * @brief Stop the CloudXR service
 *
 * @param client The client handle
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_stop_cxr_service(nv_rpc_client_t client);

/**
 * @brief Get supported CloudXR versions
 *
 * @param client The client handle
 * @param versions_out Output parameter for the versions array
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_get_supported_versions(nv_rpc_client_t client, nv_string_array_t *versions_out);

/**
 * @brief Get the OpenXR Runtime JSON file path
 *
 * @param client The client handle
 * @param path_out Output buffer for the JSON file path
 * @param path_size Size of the output buffer
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_get_cxr_service_json_path(nv_rpc_client_t client, char *path_out, size_t path_size);

/**
 * @brief Get the cryptographic key fingerprint
 *
 * @param client The client handle
 * @param algorithm The cryptographic algorithm to use
 * @param fingerprint_out Output buffer for the fingerprint hex string
 * @param fingerprint_size Size of the output buffer
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_get_crypto_key_fingerprint(nv_rpc_client_t client,
                                         nv_crypto_algorithm_t algorithm,
                                         char *fingerprint_out,
                                         size_t fingerprint_size);

/**
 * @brief Free a string array returned by the API
 *
 * @param string_array The string array to free
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_free_string_array(nv_string_array_t *string_array);

/**
 * @brief Get a human-readable error message for an error code
 *
 * @param result The error code
 * @return A string describing the error (valid until next call to this
 * function)
 */
NV_RPC_CLIENT_C_API const char *
nv_rpc_client_get_error_string(nv_rpc_result_t result);

/**
 * @brief Set the client ID and get the token
 *
 * @param client The client handle
 * @param clientId The client ID to set
 * @param token Output buffer for the token
 * @param tokenSize Size of the token buffer
 * @param tokenSizeOut Actual size of the returned token
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_set_client_id(nv_rpc_client_t client,
                            const char *clientId,
                            size_t clientIdLength,
                            unsigned char *token,
                            size_t tokenSize,
                            size_t *tokenSizeOut);

/**
 * @brief Get the current CloudXR service status
 *
 * @param client The client handle
 * @param status_out Output parameter for the service status
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_get_cxr_service_status(nv_rpc_client_t client, nv_service_status_t *status_out);

/**
 * @brief Shutdown the manager
 *
 * @param client The client handle
 * @return NV_RPC_SUCCESS on success, error code on failure
 */
NV_RPC_CLIENT_C_API nv_rpc_result_t
nv_rpc_client_shutdown_manager(nv_rpc_client_t client);

// Function pointer types for dynamic loading
// clang-format off
typedef nv_rpc_result_t (*pfn_nv_rpc_client_create)(const char *pipe_name, nv_rpc_client_t *client_out);
typedef nv_rpc_result_t (*pfn_nv_rpc_client_destroy)(nv_rpc_client_t client);
typedef nv_rpc_result_t (*pfn_nv_rpc_client_connect)(nv_rpc_client_t client);
typedef nv_rpc_result_t (*pfn_nv_rpc_client_disconnect)(nv_rpc_client_t client);
typedef nv_rpc_result_t (*pfn_nv_rpc_client_start_cxr_service)(nv_rpc_client_t client, const char *service_version, size_t service_version_length);
typedef nv_rpc_result_t (*pfn_nv_rpc_client_stop_cxr_service)(nv_rpc_client_t client);
typedef nv_rpc_result_t (*pfn_nv_rpc_client_get_supported_versions)(nv_rpc_client_t client, nv_string_array_t *versions_out);
typedef nv_rpc_result_t (*pfn_nv_rpc_client_get_cxr_service_json_path)(nv_rpc_client_t client, char *path_out, size_t path_size);
typedef nv_rpc_result_t (*pfn_nv_rpc_client_get_crypto_key_fingerprint)(nv_rpc_client_t client, nv_crypto_algorithm_t algorithm, char *fingerprint_out, size_t fingerprint_size);
typedef nv_rpc_result_t (*pfn_nv_rpc_client_free_string_array)(nv_string_array_t *string_array);
typedef const char *(*pfn_nv_rpc_client_get_error_string)(nv_rpc_result_t result);
typedef nv_rpc_result_t (*pfn_nv_rpc_client_set_client_id)(nv_rpc_client_t client, const char *clientId, size_t clientIdLength, unsigned char *token, size_t tokenSize, size_t *tokenSizeOut);
typedef nv_rpc_result_t (*pfn_nv_rpc_client_get_cxr_service_status)(nv_rpc_client_t client, nv_service_status_t *status_out);
typedef nv_rpc_result_t (*pfn_nv_rpc_client_shutdown_manager)(nv_rpc_client_t client);
// clang-format on

#ifdef __cplusplus
}
#endif
