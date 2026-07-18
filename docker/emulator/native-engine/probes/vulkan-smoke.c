#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>

static int fail(const char* operation, VkResult result) {
    fprintf(stderr, "vulkan-smoke: %s failed with VkResult %d\n", operation, result);
    return 1;
}

int main(void) {
    const VkApplicationInfo application_info = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "cloudandx-native-aemu-vulkan-smoke",
        .applicationVersion = VK_MAKE_VERSION(1, 0, 0),
        .pEngineName = "cloudandx",
        .engineVersion = VK_MAKE_VERSION(1, 0, 0),
        .apiVersion = VK_API_VERSION_1_0,
    };
    const VkInstanceCreateInfo instance_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application_info,
    };
    VkInstance instance = VK_NULL_HANDLE;
    VkResult result = vkCreateInstance(&instance_info, NULL, &instance);
    if (result != VK_SUCCESS) {
        return fail("vkCreateInstance", result);
    }

    uint32_t physical_device_count = 0;
    result = vkEnumeratePhysicalDevices(instance, &physical_device_count, NULL);
    if (result != VK_SUCCESS || physical_device_count == 0) {
        vkDestroyInstance(instance, NULL);
        return fail("vkEnumeratePhysicalDevices(count)", result);
    }

    VkPhysicalDevice* physical_devices =
        calloc(physical_device_count, sizeof(*physical_devices));
    if (physical_devices == NULL) {
        vkDestroyInstance(instance, NULL);
        fprintf(stderr, "vulkan-smoke: physical-device allocation failed\n");
        return 1;
    }
    result = vkEnumeratePhysicalDevices(instance, &physical_device_count, physical_devices);
    if (result != VK_SUCCESS) {
        free(physical_devices);
        vkDestroyInstance(instance, NULL);
        return fail("vkEnumeratePhysicalDevices(list)", result);
    }

    int passed = 0;
    for (uint32_t device_index = 0; device_index < physical_device_count && !passed;
         ++device_index) {
        VkPhysicalDeviceProperties properties;
        vkGetPhysicalDeviceProperties(physical_devices[device_index], &properties);
        if (strstr(properties.deviceName, "SwiftShader") == NULL) {
            continue;
        }

        uint32_t queue_family_count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(
            physical_devices[device_index], &queue_family_count, NULL);
        if (queue_family_count == 0) {
            continue;
        }
        VkQueueFamilyProperties* queue_families =
            calloc(queue_family_count, sizeof(*queue_families));
        if (queue_families == NULL) {
            break;
        }
        vkGetPhysicalDeviceQueueFamilyProperties(
            physical_devices[device_index], &queue_family_count, queue_families);

        uint32_t queue_family_index = UINT32_MAX;
        for (uint32_t index = 0; index < queue_family_count; ++index) {
            if (queue_families[index].queueCount > 0 &&
                (queue_families[index].queueFlags &
                 (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT | VK_QUEUE_TRANSFER_BIT))) {
                queue_family_index = index;
                break;
            }
        }
        free(queue_families);
        if (queue_family_index == UINT32_MAX) {
            continue;
        }

        const float queue_priority = 1.0f;
        const VkDeviceQueueCreateInfo queue_info = {
            .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = queue_family_index,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };
        const VkDeviceCreateInfo device_info = {
            .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
        };
        VkDevice device = VK_NULL_HANDLE;
        result = vkCreateDevice(
            physical_devices[device_index], &device_info, NULL, &device);
        if (result != VK_SUCCESS) {
            continue;
        }

        VkQueue queue = VK_NULL_HANDLE;
        vkGetDeviceQueue(device, queue_family_index, 0, &queue);
        const VkCommandPoolCreateInfo pool_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = queue_family_index,
        };
        VkCommandPool command_pool = VK_NULL_HANDLE;
        result = vkCreateCommandPool(device, &pool_info, NULL, &command_pool);
        if (result != VK_SUCCESS) {
            vkDestroyDevice(device, NULL);
            continue;
        }

        const VkCommandBufferAllocateInfo allocate_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = command_pool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        VkCommandBuffer command_buffer = VK_NULL_HANDLE;
        result = vkAllocateCommandBuffers(device, &allocate_info, &command_buffer);
        if (result == VK_SUCCESS) {
            const VkCommandBufferBeginInfo begin_info = {
                .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            };
            result = vkBeginCommandBuffer(command_buffer, &begin_info);
        }
        if (result == VK_SUCCESS) {
            result = vkEndCommandBuffer(command_buffer);
        }

        VkFence fence = VK_NULL_HANDLE;
        if (result == VK_SUCCESS) {
            const VkFenceCreateInfo fence_info = {
                .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            };
            result = vkCreateFence(device, &fence_info, NULL, &fence);
        }
        if (result == VK_SUCCESS) {
            const VkSubmitInfo submit_info = {
                .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .commandBufferCount = 1,
                .pCommandBuffers = &command_buffer,
            };
            result = vkQueueSubmit(queue, 1, &submit_info, fence);
        }
        if (result == VK_SUCCESS) {
            result = vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_C(30000000000));
        }
        if (result == VK_SUCCESS) {
            printf("vulkan-smoke: device=%s api=%u.%u.%u queue-family=%u PASS\n",
                   properties.deviceName,
                   VK_VERSION_MAJOR(properties.apiVersion),
                   VK_VERSION_MINOR(properties.apiVersion),
                   VK_VERSION_PATCH(properties.apiVersion),
                   queue_family_index);
            passed = 1;
        }

        if (fence != VK_NULL_HANDLE) {
            vkDestroyFence(device, fence, NULL);
        }
        vkDestroyCommandPool(device, command_pool, NULL);
        vkDestroyDevice(device, NULL);
    }

    free(physical_devices);
    vkDestroyInstance(instance, NULL);
    if (!passed) {
        fprintf(stderr,
                "vulkan-smoke: no SwiftShader device completed device/queue/submit/fence\n");
        return 1;
    }
    return 0;
}
