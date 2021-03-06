#include <Cocoa/Cocoa.h> // APPKIT
#include <CoreGraphics/CoreGraphics.h> 
#include <mach/mach_time.h> // mach_absolute_time
#include <stdio.h> // printf for debugging purpose
#include <sys/stat.h>
#include <libkern/OSAtomic.h>
#include <pthread.h>
#include <semaphore.h>
#include <Carbon/Carbon.h>
#include <dlfcn.h> // dlsym
#include <metalkit/metalkit.h>
#include <metal/metal.h>

// TODO(joon) introspection?
#undef internal
#undef assert

// TODO(joon) shared.h file for files that are shared across platforms?
#include "hb_types.h"
#include "hb_intrinsic.h"
#include "hb_platform.h"
#include "hb_math.h"
#include "hb_random.h"
#include "hb_simd.h"
#include "hb_render_group.h"

#include "hb_metal.cpp"
#include "hb_render_group.cpp"

// TODO(joon): Get rid of global variables?
global v2 last_mouse_p;
global v2 mouse_diff;

global u64 last_time;

global b32 is_game_running;
global dispatch_semaphore_t semaphore;

internal u64 
mach_time_diff_in_nano_seconds(u64 begin, u64 end, f32 nano_seconds_per_tick)
{
    return (u64)(((end - begin)*nano_seconds_per_tick));
}

PLATFORM_GET_FILE_SIZE(macos_get_file_size) 
{
    u64 result = 0;

    int File = open(filename, O_RDONLY);
    struct stat FileStat;
    fstat(File , &FileStat); 
    result = FileStat.st_size;
    close(File);

    return result;
}

PLATFORM_READ_FILE(debug_macos_read_file)
{
    PlatformReadFileResult Result = {};

    int File = open(filename, O_RDONLY);
    int Error = errno;
    if(File >= 0) // NOTE : If the open() succeded, the return value is non-negative value.
    {
        struct stat FileStat;
        fstat(File , &FileStat); 
        off_t fileSize = FileStat.st_size;

        if(fileSize > 0)
        {
            // TODO/Joon : NO MORE OS LEVEL ALLOCATION!
            Result.size = fileSize;
            Result.memory = (u8 *)malloc(Result.size);
            if(read(File, Result.memory, fileSize) == -1)
            {
                free(Result.memory);
                Result.size = 0;
            }
        }

        close(File);
    }

    return Result;
}

PLATFORM_WRITE_ENTIRE_FILE(debug_macos_write_entire_file)
{
    int file = open(file_name, O_WRONLY|O_CREAT|O_TRUNC, S_IRWXU);

    if(file >= 0) 
    {
        if(write(file, memory_to_write, size) == -1)
        {
            // TODO(joon) : LOG here
        }

        close(file);
    }
    else
    {
        // TODO(joon) :LOG
        printf("Failed to create file\n");
    }
}

PLATFORM_FREE_FILE_MEMORY(debug_macos_free_file_memory)
{
    free(memory);
}

@interface 
app_delegate : NSObject<NSApplicationDelegate>
@end
@implementation app_delegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    [NSApp stop:nil];

    // Post empty event: without it we can't put application to front
    // for some reason (I get this technique from GLFW source).
    NSAutoreleasePool* pool = [NSAutoreleasePool new];
    NSEvent* event =
        [NSEvent otherEventWithType: NSApplicationDefined
                 location: NSMakePoint(0, 0)
                 modifierFlags: 0
                 timestamp: 0
                 windowNumber: 0
                 context: nil
                 subtype: 0
                 data1: 0
                 data2: 0];
    [NSApp postEvent: event atStart: YES];
    [pool drain];
}

@end

#define check_ns_error(error)\
{\
    if(error)\
    {\
        printf("check_metal_error failed inside the domain: %s code: %ld\n", [error.domain UTF8String], (long)error.code);\
        assert(0);\
    }\
}\


internal CVReturn 
display_link_callback(CVDisplayLinkRef displayLink, const CVTimeStamp* current_time, const CVTimeStamp* output_time,
                CVOptionFlags ignored_0, CVOptionFlags* ignored_1, void* displayLinkContext)
{
    // NOTE(joon) : display link automatically adjust the framerate.
    // TODO(joon) : Find out in what condition it adjusts the framerate?
    u32 last_frame_diff = (u32)(output_time->hostTime - last_time);
    u32 current_time_diff = (u32)(output_time->hostTime - current_time->hostTime);

    f32 last_frame_time_elapsed =last_frame_diff/(f32)output_time->videoTimeScale;
    f32 current_time_elapsed = current_time_diff/(f32)output_time->videoTimeScale;
    
    //printf("last frame diff: %.6f, current time diff: %.6f\n",  last_frame_time_elapsed, current_time_elapsed);

    last_time = output_time->hostTime;
    return kCVReturnSuccess;
}

internal void
macos_handle_event(NSApplication *app, NSWindow *window, PlatformInput *platform_input)
{
    NSPoint mouse_location = [NSEvent mouseLocation];
    NSRect frame_rect = [window frame];
    NSRect content_rect = [window contentLayoutRect];

    v2 bottom_left_p = {};
    bottom_left_p.x = frame_rect.origin.x;
    bottom_left_p.y = frame_rect.origin.y;

    v2 content_rect_dim = {}; 
    content_rect_dim.x = content_rect.size.width; 
    content_rect_dim.y = content_rect.size.height;

    v2 rel_mouse_location = {};
    rel_mouse_location.x = mouse_location.x - bottom_left_p.x;
    rel_mouse_location.y = mouse_location.y - bottom_left_p.y;

    f32 mouse_speed_when_clipped = 0.08f;
    if(rel_mouse_location.x >= 0.0f && rel_mouse_location.x < content_rect_dim.x)
    {
        mouse_diff.x = mouse_location.x - last_mouse_p.x;
    }
    else if(rel_mouse_location.x < 0.0f)
    {
        mouse_diff.x = -mouse_speed_when_clipped;
    }
    else
    {
        mouse_diff.x = mouse_speed_when_clipped;
    }

    if(rel_mouse_location.y >= 0.0f && rel_mouse_location.y < content_rect_dim.y)
    {
        mouse_diff.y = mouse_location.y - last_mouse_p.y;
    }
    else if(rel_mouse_location.y < 0.0f)
    {
        mouse_diff.y = -mouse_speed_when_clipped;
    }
    else
    {
        mouse_diff.y = mouse_speed_when_clipped;
    }

    // NOTE(joon) : MacOS screen coordinate is bottom-up, so just for the convenience, make y to be bottom-up
    mouse_diff.y *= -1.0f;

    last_mouse_p.x = mouse_location.x;
    last_mouse_p.y = mouse_location.y;

    //printf("%f, %f\n", mouse_diff.x, mouse_diff.y);

    // TODO : Check if this loop has memory leak.
    while(1)
    {
        NSEvent *event = [app nextEventMatchingMask:NSAnyEventMask
                         untilDate:nil
                            inMode:NSDefaultRunLoopMode
                           dequeue:YES];
        if(event)
        {
            switch([event type])
            {
                case NSEventTypeKeyUp:
                case NSEventTypeKeyDown:
                {
                    b32 was_down = event.ARepeat;
                    b32 is_down = ([event type] == NSEventTypeKeyDown);

                    if((is_down != was_down) || !is_down)
                    {
                        //printf("isDown : %d, WasDown : %d", is_down, was_down);
                        u16 key_code = [event keyCode];
                        if(key_code == kVK_Escape)
                        {
                            is_game_running = false;
                        }
                        else if(key_code == kVK_ANSI_W)
                        {
                            platform_input->move_up = is_down;
                        }
                        else if(key_code == kVK_ANSI_A)
                        {
                            platform_input->move_left = is_down;
                        }
                        else if(key_code == kVK_ANSI_S)
                        {
                            platform_input->move_down = is_down;
                        }
                        else if(key_code == kVK_ANSI_D)
                        {
                            platform_input->move_right = is_down;
                        }

                        else if(key_code == kVK_ANSI_I)
                        {
                            platform_input->action_up = is_down;
                        }
                        else if(key_code == kVK_ANSI_J)
                        {
                            platform_input->action_left = is_down;
                        }
                        else if(key_code == kVK_ANSI_K)
                        {
                            platform_input->action_down = is_down;
                        }
                        else if(key_code == kVK_ANSI_L)
                        {
                            platform_input->action_right = is_down;
                        }

                        else if(key_code == kVK_LeftArrow)
                        {
                            platform_input->action_left = is_down;
                        }
                        else if(key_code == kVK_RightArrow)
                        {
                            platform_input->action_right = is_down;
                        }
                        else if(key_code == kVK_UpArrow)
                        {
                            platform_input->action_up = is_down;
                        }
                        else if(key_code == kVK_DownArrow)
                        {
                            platform_input->action_down = is_down;
                        }

                        else if(key_code == kVK_Space)
                        {
                            platform_input->space = is_down;
                        }

                        else if(key_code == kVK_Return)
                        {
                            if(is_down)
                            {
                                NSWindow *window = [event window];
                                // TODO : proper buffer resize here!
                                [window toggleFullScreen:0];
                            }
                        }
                    }
                }break;

                default:
                {
                    [app sendEvent : event];
                }
            }
        }
        else
        {
            break;
        }
    }
} 

// TODO(joon) : It seems like this combines read & write barrier, but make sure
// TODO(joon) : mfence?(DSB)
#define write_barrier() OSMemoryBarrier(); 
#define read_barrier() OSMemoryBarrier();

struct macos_thread
{
    u32 ID;
    thread_work_queue *queue;

    // TODO(joon): I like the idea of each thread having a random number generator that they can use throughout the whole process
    // though what should happen to the 0th thread(which does not have this structure)?
    simd_random_series series;
};

// NOTE(joon) : use this to add what thread should do
internal 
THREAD_WORK_CALLBACK(print_string)
{
    char *stringToPrint = (char *)data;
    printf("%s\n", stringToPrint);
}

#if 0
struct thread_work_raytrace_tile_data
{
    raytracer_data raytracer_input;
};

global volatile u64 total_bounced_ray_count;
internal 
THREAD_WORK_CALLBACK(thread_work_callback_render_tile)
{
    thread_work_raytrace_tile_data *raytracer_data = (thread_work_raytrace_tile_data *)data;

    //raytracer_output output = render_raytraced_image_tile(&raytracer_data->raytracer_input);
    raytracer_output output = render_raytraced_image_tile_simd(&raytracer_data->raytracer_input);

    // TODO(joon): double check the return value of the OSAtomicIncrement32, is it really a post incremented value? 
    i32 rendered_tile_count = OSAtomicIncrement32Barrier((volatile int32_t *)&raytracer_data->raytracer_input.world->rendered_tile_count);

    u64 ray_count = raytracer_data->raytracer_input.ray_per_pixel_count*
                    (raytracer_data->raytracer_input.one_past_max_x - raytracer_data->raytracer_input.min_x) * 
                    (raytracer_data->raytracer_input.one_past_max_y - raytracer_data->raytracer_input.min_y);

    OSAtomicAdd64Barrier(ray_count, (volatile int64_t *)&raytracer_data->raytracer_input.world->total_ray_count);
    OSAtomicAdd64Barrier(output.bounced_ray_count, (volatile int64_t *)&raytracer_data->raytracer_input.world->bounced_ray_count);

    printf("%dth tile finished with %llu rays\n", rendered_tile_count, raytracer_data->raytracer_input.world->total_ray_count);
}
#endif

// NOTE(joon): This is single producer multiple consumer - 
// meaning, it _does not_ provide any thread safety
// For example, if the two threads try to add the work item,
// one item might end up over-writing the other one
internal void
macos_add_thread_work_item(thread_work_queue *queue,
                            thread_work_callback *work_callback,
                            void *data)
{
    assert(data); // TODO(joon) : There might be a work that does not need any data?
    thread_work_item *item = queue->items + queue->add_index;
    item->callback = work_callback;
    item->data = data;
    item->written = true;

    write_barrier();
    queue->add_index++;

    // increment the semaphore value by 1
    dispatch_semaphore_signal(semaphore);
}

internal b32
macos_do_thread_work_item(thread_work_queue *queue, u32 thread_index)
{
    b32 did_work = false;
    if(queue->work_index != queue->add_index)
    {
        int original_work_index = queue->work_index;
        int desired_work_index = original_work_index + 1;

        if(OSAtomicCompareAndSwapIntBarrier(original_work_index, desired_work_index, &queue->work_index))
        {
            thread_work_item *item = queue->items + original_work_index;
            item->callback(item->data);

            //printf("Thread %u: Finished working\n", thread_index);
            did_work = true;
        }
    }

    return did_work;
}

internal 
PLATFORM_COMPLETE_ALL_THREAD_WORK_QUEUE_ITEMS(macos_complete_all_thread_work_queue_items)
{
    // TODO(joon): If there was a last thread that was working on the item,
    // this does not guarantee that the last work will be finished.
    // Maybe add some flag inside the thread? (sleep / working / ...)
    while(queue->work_index != queue->add_index) 
    {
        macos_do_thread_work_item(queue, 0);
    }
}


internal void*
thread_proc(void *data)
{
    macos_thread *thread = (macos_thread *)data;
    while(1)
    {
        if(macos_do_thread_work_item(thread->queue, thread->ID))
        {
        }
        else
        {
            // dispatch semaphore puts the thread into sleep until the semaphore is signaled
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        }
    }

    return 0;
}

f32 cube_vertices[] = 
{
    0.5f, -0.5f, -0.5f,
    0.5f, 0.5f, -0.5f,
    -0.5f, 0.5f, -0.5f,
    -0.5f, -0.5f, -0.5f, 

    0.5f, -0.5f, 0.5f,
    0.5f, 0.5f, 0.5f,
    -0.5f, 0.5f, 0.5f,
    -0.5f, -0.5f, 0.5f, 
};

f32 cube_normals[] = 
{
    0.5f, -0.5f, -0.5f,
    0.5f, 0.5f, -0.5f,
    -0.5f, 0.5f, -0.5f,
    -0.5f, -0.5f, -0.5f, 

    0.5f, -0.5f, 0.5f,
    0.5f, 0.5f, 0.5f,
    -0.5f, 0.5f, 0.5f,
    -0.5f, -0.5f, 0.5f, 
};

u32 cube_outward_facing_indices[]
{
    //+z
    4, 5, 7,
    5, 6, 7,

    //-z
    0, 2, 1, 
    0, 3, 2, 

    //+x
    4, 0, 5,
    0, 1, 5,

    //-x
    2, 3, 7,
    2, 7, 6,

    //+y
    1, 2, 6,
    1, 6, 5,

    //-y
    3, 0, 4,
    3, 4, 7
};

// TODO(joon) Later, we can make this to also 'stream' the meshes(just like the other assets), and put them inside the render mesh
// so that the graphics API can render them.
internal void
metal_render_and_display(MetalRenderContext *render_context, PlatformRenderPushBuffer *render_push_buffer, u32 window_width, u32 window_height)
{
    // NOTE(joon): renderpass descriptor is already configured for this frame
    MTLRenderPassDescriptor *this_frame_descriptor = render_context->view.currentRenderPassDescriptor;

    //renderpass_descriptor.colorAttachments[0].texture = ;
    this_frame_descriptor.colorAttachments[0].clearColor = {render_push_buffer->clear_color.r, 
                                                            render_push_buffer->clear_color.g, 
                                                            render_push_buffer->clear_color.b, 
                                                            1};
    this_frame_descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    this_frame_descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

    this_frame_descriptor.depthAttachment.clearDepth = 1.0f;
    this_frame_descriptor.depthAttachment.loadAction = MTLLoadActionClear;
    this_frame_descriptor.depthAttachment.storeAction = MTLStoreActionDontCare;

    if(this_frame_descriptor)
    {
        id<MTLCommandBuffer> command_buffer = [render_context->command_queue commandBuffer];
        // TODO(joon) double check whether this thing is freed automatically or not
        // if not, we can pull this outside, and put this inside the render context
        id<MTLRenderCommandEncoder> render_encoder = [command_buffer renderCommandEncoderWithDescriptor: this_frame_descriptor];

        metal_set_viewport(render_encoder, 0, 0, window_width, window_height, 0, 1);
        metal_set_scissor_rect(render_encoder, 0, 0, window_width, window_height);
        metal_set_triangle_fill_mode(render_encoder, MTLTriangleFillModeFill);
        metal_set_front_facing_winding(render_encoder, MTLWindingCounterClockwise);
        metal_set_cull_mode(render_encoder, MTLCullModeBack);
        metal_set_detph_stencil_state(render_encoder, render_context->depth_state);

        PerFrameData per_frame_data = {};
        per_frame_data.proj_view = render_push_buffer->proj_view; // already calculated from the game code

        u32 size = sizeof(per_frame_data);

        // NOTE(joon) per frame data is always the 0th buffer
        metal_set_vertex_bytes(render_encoder, &per_frame_data, sizeof(per_frame_data), 0);

        u32 voxel_instance_count = 0;
        for(u32 consumed = 0;
                consumed < render_push_buffer->used;
                )
        {
            RenderEntryHeader *header = (RenderEntryHeader *)((u8 *)render_push_buffer->base + consumed);

            switch(header->type)
            {
                // TODO(joon) we can also do the similar thing as the voxels,
                // which is allocating the managed buffer and instance-drawing the lines
                case RenderEntryType_Line:
                {
                    RenderEntryLine *entry = (RenderEntryLine *)((u8 *)render_push_buffer->base + consumed);
                    metal_set_pipeline(render_encoder, render_context->line_pipeline_state);
                    f32 start_and_end[6] = {entry->start.x, entry->start.y, entry->start.z, entry->end.x, entry->end.y, entry->end.z};

                    metal_set_vertex_bytes(render_encoder, start_and_end, sizeof(f32) * array_count(start_and_end), 1);
                    metal_set_vertex_bytes(render_encoder, &entry->color, sizeof(entry->color), 2);

                    metal_draw_non_indexed(render_encoder, MTLPrimitiveTypeLine, 0, 2);

                    consumed += sizeof(*entry);
                }break;
#if 0
                case RenderEntryType_Voxel:
                {
                    RenderEntryVoxel *entry = (RenderEntryVoxel *)((u8 *)push_buffer_base + consumed);

                    metal_append_to_managed_buffer(&render_context->voxel_position_buffer, &entry->p, sizeof(entry->p));
                    metal_append_to_managed_buffer(&render_context->voxel_color_buffer, &entry->color, sizeof(entry->color));

                    voxel_instance_count++;

                    consumed += sizeof(*entry);
                }break;
#endif

                case RenderEntryType_AABB:
                {
                    RenderEntryAABB *entry = (RenderEntryAABB *)((u8 *)render_push_buffer->base + consumed);
                    consumed += sizeof(*entry);

                    m4x4 model = st_m4x4(entry->p, entry->dim);
                    model = transpose(model); // make the matrix column-major
                    PerObjectData per_object_data = {};
                    per_object_data.model = model;
                    per_object_data.color = entry->color;

                    metal_set_pipeline(render_encoder, render_context->cube_pipeline_state);
                    metal_set_vertex_bytes(render_encoder, &per_object_data, sizeof(per_object_data), 1);
                    metal_set_vertex_bytes(render_encoder, cube_vertices, sizeof(f32) * array_count(cube_vertices), 2);
                    metal_set_vertex_bytes(render_encoder, cube_normals, sizeof(f32) * array_count(cube_normals), 3);

                    metal_draw_indexed_instances(render_encoder, MTLPrimitiveTypeTriangle, 
                            render_context->cube_outward_facing_index_buffer.buffer, array_count(cube_outward_facing_indices), 1);
                }break;

                case RenderEntryType_Cube:
                {
                    RenderEntryCube *entry = (RenderEntryCube *)((u8 *)render_push_buffer->base + consumed);
                    consumed += sizeof(*entry);

                    m4x4 model = srt_m4x4(entry->p, entry->orientation, entry->dim);
                    model = transpose(model); // make the matrix column-major
                    PerObjectData per_object_data = {};
                    per_object_data.model = model;
                    per_object_data.color = entry->color;

                    metal_set_pipeline(render_encoder, render_context->cube_pipeline_state);
                    metal_set_vertex_bytes(render_encoder, &per_object_data, sizeof(per_object_data), 1);
                    metal_set_vertex_bytes(render_encoder, cube_vertices, sizeof(f32) * array_count(cube_vertices), 2);
                    metal_set_vertex_bytes(render_encoder, cube_normals, sizeof(f32) * array_count(cube_normals), 3);

                    metal_draw_indexed_instances(render_encoder, MTLPrimitiveTypeTriangle, 
                            render_context->cube_outward_facing_index_buffer.buffer, array_count(cube_outward_facing_indices), 1);
                }break;
            }
        }

        // NOTE(joon) draw axis lines
        // TODO(joon) maybe it's more wise to pull the line into seperate entry, and 
        // instance draw them just by the position buffer
        metal_set_pipeline(render_encoder, render_context->line_pipeline_state);

        f32 x_axis[] = {0.0f, 0.0f, 0.0f, 100.0f, 0.0f, 0.0f};
        v3 x_axis_color = V3(1, 0, 0);
        f32 y_axis[] = {0.0f, 0.0f, 0.0f, 0.0f, 100.0f, 0.0f};
        v3 y_axis_color = V3(0, 1, 0);
        f32 z_axis[] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 100.0f};
        v3 z_axis_color = V3(0, 0, 1);

        // x axis
        metal_set_vertex_bytes(render_encoder, x_axis, sizeof(f32) * array_count(x_axis), 1);
        metal_set_vertex_bytes(render_encoder, &x_axis_color, sizeof(v3), 2);
        metal_draw_non_indexed(render_encoder, MTLPrimitiveTypeLine, 0, 2);

        // y axis
        metal_set_vertex_bytes(render_encoder, y_axis, sizeof(f32) * array_count(y_axis), 1);
        metal_set_vertex_bytes(render_encoder, &y_axis_color, sizeof(v3), 2);
        metal_draw_non_indexed(render_encoder, MTLPrimitiveTypeLine, 0, 2);

        // z axis
        metal_set_vertex_bytes(render_encoder, z_axis, sizeof(f32) * array_count(z_axis), 1);
        metal_set_vertex_bytes(render_encoder, &z_axis_color, sizeof(v3), 2);
        metal_draw_non_indexed(render_encoder, MTLPrimitiveTypeLine, 0, 2);

        if(voxel_instance_count)
        {
            // NOTE(joon) as we are drawing a lot of voxels, we are going to treat the voxels in a special way by
            // using the instancing.
            metal_flush_managed_buffer(&render_context->voxel_position_buffer);
            metal_flush_managed_buffer(&render_context->voxel_color_buffer);

            metal_set_pipeline(render_encoder, render_context->voxel_pipeline_state);
            metal_set_vertex_bytes(render_encoder, cube_vertices, sizeof(f32) * array_count(cube_vertices), 0);
            metal_set_vertex_buffer(render_encoder, render_context->voxel_position_buffer.buffer, 0, 2);
            metal_set_vertex_buffer(render_encoder, render_context->voxel_color_buffer.buffer, 0, 3);

            //metal_draw_primitives(render_encoder, MTLPrimitiveTypeTriangle, 0, array_count(voxel_vertices)/3, 0, voxel_count);

            metal_draw_indexed_instances(render_encoder, MTLPrimitiveTypeTriangle, 
                    render_context->cube_outward_facing_index_buffer.buffer, array_count(cube_outward_facing_indices), voxel_instance_count);
        }
#if 0
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType 
                   indexCount:(NSUInteger)indexCount 
                    indexType:(MTLIndexType)indexType 
                  indexBuffer:(id<MTLBuffer>)indexBuffer 
            indexBufferOffset:(NSUInteger)indexBufferOffset 
                instanceCount:(NSUInteger)instanceCount;
#endif


        metal_end_encoding(render_encoder);

        metal_present_drawable(command_buffer, render_context->view);

        // TODO(joon): Sync with the swap buffer!
        metal_commit_command_buffer(command_buffer, render_context->view);
    }
}

// NOTE(joon): returns the base path where all the folders(code, misc, data) are located
internal void
macos_get_base_path(char *dest)
{
    NSString *app_path_string = [[NSBundle mainBundle] bundlePath];
    u32 length = [app_path_string lengthOfBytesUsingEncoding: NSUTF8StringEncoding];
    unsafe_string_append(dest, 
                        [app_path_string cStringUsingEncoding: NSUTF8StringEncoding],
                        length);

    u32 slash_to_delete_count = 2;
    for(u32 index = length-1;
            index >= 0;
            --index)
    {
        if(dest[index] == '/')
        {
            slash_to_delete_count--;
            if(slash_to_delete_count == 0)
            {
                break;
            }
        }
        else
        {
            dest[index] = 0;
        }
    }
}

internal time_t
macos_get_last_modified_time(char *file_name)
{
    time_t result = 0; 

    struct stat file_stat = {};
    stat(file_name, &file_stat); 
    result = file_stat.st_mtime;

    return result;
}

struct MacOSGameCode
{
    void *library;
    time_t last_modified_time; // u32 bit integer
    UpdateAndRender *update_and_render;
};

internal void
macos_load_game_code(MacOSGameCode *game_code, char *file_name)
{
    // NOTE(joon) dlclose does not actually unload the dll!!!
    // dll only gets unloaded if there is no object that is referencing the dll.
    // TODO(joon) library should be remain open? If so, we need another way to 
    // actually unload the dll so that the fresh dll can be loaded.
    if(game_code->library)
    {
        int error = dlclose(game_code->library);
        game_code->update_and_render = 0;
        game_code->last_modified_time = 0;
        game_code->library = 0;
    }

    void *library = dlopen(file_name, RTLD_LAZY|RTLD_GLOBAL);
    if(library)
    {
        game_code->library = library;
        game_code->last_modified_time = macos_get_last_modified_time(file_name);
        game_code->update_and_render = (UpdateAndRender *)dlsym(library, "update_and_render");
    }
}

int 
main(void)
{ 
    struct mach_timebase_info mach_time_info;
    mach_timebase_info(&mach_time_info);
    f32 nano_seconds_per_tick = ((f32)mach_time_info.numer/(f32)mach_time_info.denom);

    char *lock_file_path = "/Volumes/meka/hb_engine/build/hb.app/Contents/MacOS/lock.tmp";
    char *game_code_path = "/Volumes/meka/hb_engine/build/hb.app/Contents/MacOS/hb.dylib";
    MacOSGameCode macos_game_code = {};
    macos_load_game_code(&macos_game_code, game_code_path);
 
    u32 random_seed = time(NULL);
    RandomSeries series = start_random_series(random_seed); 

    //TODO : writefile?
    PlatformAPI platform_api = {};
    platform_api.read_file = debug_macos_read_file;
    platform_api.write_entire_file = debug_macos_write_entire_file;
    platform_api.free_file_memory = debug_macos_free_file_memory;

    PlatformMemory platform_memory = {};

    platform_memory.permanent_memory_size = gigabytes(1);
    platform_memory.transient_memory_size = gigabytes(3);
    u64 total_size = platform_memory.permanent_memory_size + platform_memory.transient_memory_size;
    vm_allocate(mach_task_self(), 
                (vm_address_t *)&platform_memory.permanent_memory,
                total_size, 
                VM_FLAGS_ANYWHERE);
    platform_memory.transient_memory = (u8 *)platform_memory.permanent_memory + platform_memory.permanent_memory_size;

    PlatformReadFileResult font = debug_macos_read_file("/Users/mekalopo/Library/Fonts/InputMonoCompressed-Light.ttf");

    i32 window_width = 1920;
    i32 window_height = 1080;

    u32 target_frames_per_second = 60;
    f32 target_seconds_per_frame = 1.0f/(f32)target_frames_per_second;
    u32 target_nano_seconds_per_frame = (u32)(target_seconds_per_frame*sec_to_nano_sec);
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy :NSApplicationActivationPolicyRegular];
    app_delegate *delegate = [app_delegate new];
    [app setDelegate: delegate];

    NSMenu *app_main_menu = [NSMenu alloc];
    NSMenuItem *menu_item_with_item_name = [NSMenuItem new];
    [app_main_menu addItem : menu_item_with_item_name];
    [NSApp setMainMenu:app_main_menu];

    NSMenu *SubMenuOfMenuItemWithAppName = [NSMenu alloc];
    NSMenuItem *quitMenuItem = [[NSMenuItem alloc] initWithTitle:@"Quit" 
                                                    action:@selector(terminate:)  // Decides what will happen when the menu is clicked or selected
                                                    keyEquivalent:@"q"];
    [SubMenuOfMenuItemWithAppName addItem:quitMenuItem];
    [menu_item_with_item_name setSubmenu:SubMenuOfMenuItemWithAppName];

    // TODO(joon): when connected to the external display, this should be window_width and window_height
    // but if not, this should be window_width/2 and window_height/2. Why?
    NSRect window_rect = NSMakeRect(100.0f, 100.0f, (f32)window_width, (f32)window_height);
    //NSRect window_rect = NSMakeRect(100.0f, 100.0f, (f32)window_width/2.0f, (f32)window_height/2.0f);

    NSWindow *window = [[NSWindow alloc] initWithContentRect : window_rect
                                        // Apple window styles : https://developer.apple.com/documentation/appkit/nswindow/stylemask
                                        styleMask : NSTitledWindowMask|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
                                        backing : NSBackingStoreBuffered
                                        defer : NO];

    NSString *app_name = [[NSProcessInfo processInfo] processName];
    [window setTitle:app_name];
    [window makeKeyAndOrderFront:0];
    [window makeKeyWindow];
    [window makeMainWindow];

    char base_path[256] = {};
    macos_get_base_path(base_path);

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSString *name = device.name;
    bool has_unified_memory = device.hasUnifiedMemory;

    MTKView *view = [[MTKView alloc] initWithFrame : window_rect
                                        device:device];
    CAMetalLayer *metal_layer = (CAMetalLayer*)[view layer];

    // load vkGetInstanceProcAddr
    //macos_initialize_vulkan(&render_context, metal_layer);

    [window setContentView:view];
    view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;

    MTLDepthStencilDescriptor *depth_descriptor = [MTLDepthStencilDescriptor new];
    depth_descriptor.depthCompareFunction = MTLCompareFunctionLess;
    depth_descriptor.depthWriteEnabled = true;
    id<MTLDepthStencilState> depth_state = [device newDepthStencilStateWithDescriptor:depth_descriptor];
    [depth_descriptor release];

    NSError *error;
    // TODO(joon) : Put the metallib file inside the app
    char metallib_path[256] = {};
    unsafe_string_append(metallib_path, base_path);
    unsafe_string_append(metallib_path, "code/shader/shader.metallib");

    // TODO(joon) : maybe just use newDefaultLibrary? If so, figure out where should we put the .metal files
    id<MTLLibrary> shader_library = [device newLibraryWithFile:[[NSString alloc] initWithCString:metallib_path
                                                                                    encoding:NSUTF8StringEncoding] 
                                                                error: &error];
    check_ns_error(error);

    id<MTLFunction> voxel_vertex = [shader_library newFunctionWithName:@"voxel_vertex"];
    id<MTLFunction> voxel_frag = [shader_library newFunctionWithName:@"voxel_frag"];
    MTLRenderPipelineDescriptor *voxel_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
    voxel_pipeline_descriptor.label = @"Voxel Pipeline";
    voxel_pipeline_descriptor.vertexFunction = voxel_vertex;
    voxel_pipeline_descriptor.fragmentFunction = voxel_frag;
    voxel_pipeline_descriptor.sampleCount = 1;
    voxel_pipeline_descriptor.rasterSampleCount = voxel_pipeline_descriptor.sampleCount;
    voxel_pipeline_descriptor.rasterizationEnabled = true;
    voxel_pipeline_descriptor.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    voxel_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    voxel_pipeline_descriptor.colorAttachments[0].writeMask = MTLColorWriteMaskAll;
    voxel_pipeline_descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat;

    id<MTLRenderPipelineState> voxel_pipeline_state = [device newRenderPipelineStateWithDescriptor:voxel_pipeline_descriptor
                                                                error:&error];

    id<MTLFunction> cube_vertex = [shader_library newFunctionWithName:@"cube_vertex"];
    id<MTLFunction> cube_frag = [shader_library newFunctionWithName:@"cube_frag"];
    MTLRenderPipelineDescriptor *cube_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
    cube_pipeline_descriptor.label = @"Cube Pipeline";
    cube_pipeline_descriptor.vertexFunction = cube_vertex;
    cube_pipeline_descriptor.fragmentFunction = cube_frag;
    cube_pipeline_descriptor.sampleCount = 1;
    cube_pipeline_descriptor.rasterSampleCount = cube_pipeline_descriptor.sampleCount;
    cube_pipeline_descriptor.rasterizationEnabled = true;
    cube_pipeline_descriptor.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    cube_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    cube_pipeline_descriptor.colorAttachments[0].writeMask = MTLColorWriteMaskAll;
    cube_pipeline_descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat;

    id<MTLRenderPipelineState> cube_pipeline_state = [device newRenderPipelineStateWithDescriptor:cube_pipeline_descriptor
                                                                error:&error];

    id<MTLFunction> line_vertex = [shader_library newFunctionWithName:@"line_vertex"];
    id<MTLFunction> line_frag = [shader_library newFunctionWithName:@"line_frag"];
    MTLRenderPipelineDescriptor *line_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
    line_pipeline_descriptor.label = @"Line Pipeline";
    line_pipeline_descriptor.vertexFunction = line_vertex;
    line_pipeline_descriptor.fragmentFunction = line_frag;
    line_pipeline_descriptor.sampleCount = 1;
    line_pipeline_descriptor.rasterSampleCount = line_pipeline_descriptor.sampleCount;
    line_pipeline_descriptor.rasterizationEnabled = true;
    line_pipeline_descriptor.inputPrimitiveTopology = MTLPrimitiveTopologyClassLine;
    line_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    line_pipeline_descriptor.colorAttachments[0].writeMask = MTLColorWriteMaskAll;
    line_pipeline_descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat;

    id<MTLRenderPipelineState> line_pipeline_state = [device newRenderPipelineStateWithDescriptor:line_pipeline_descriptor
                                                                error:&error];

    check_ns_error(error);

    id<MTLCommandQueue> command_queue = [device newCommandQueue];

    MetalRenderContext metal_render_context = {};
    metal_render_context.device = device;
    metal_render_context.view = view;
    metal_render_context.command_queue = command_queue;
    metal_render_context.depth_state = depth_state;
    metal_render_context.voxel_pipeline_state = voxel_pipeline_state;
    metal_render_context.cube_pipeline_state = cube_pipeline_state;
    metal_render_context.line_pipeline_state = line_pipeline_state;
    // TODO(joon) More robust way to manage these buffers??(i.e asset system?)
    metal_render_context.voxel_position_buffer = metal_create_managed_buffer(device, megabytes(16));
    metal_render_context.voxel_color_buffer = metal_create_managed_buffer(device, megabytes(4));
    metal_render_context.cube_outward_facing_index_buffer = metal_create_managed_buffer(device, sizeof(u32) * array_count(cube_outward_facing_indices));
    metal_append_to_managed_buffer(&metal_render_context.cube_outward_facing_index_buffer, 
                                    cube_outward_facing_indices, 
                                    metal_render_context.cube_outward_facing_index_buffer.max_size);

    CVDisplayLinkRef display_link;
    if(CVDisplayLinkCreateWithActiveCGDisplays(&display_link)== kCVReturnSuccess)
    {
        CVDisplayLinkSetOutputCallback(display_link, display_link_callback, 0); 
        CVDisplayLinkStart(display_link);
    }

    PlatformInput platform_input = {};

    PlatformRenderPushBuffer platform_render_push_buffer = {};
    platform_render_push_buffer.total_size = megabytes(16);
    platform_render_push_buffer.base = (u8 *)malloc(platform_render_push_buffer.total_size);
    // TODO(joon) Make sure to update this value whenever we resize the window
    platform_render_push_buffer.width_over_height = (f32)window_width / (f32)window_height;

    [app activateIgnoringOtherApps:YES];
    [app run];

    u64 last_time = mach_absolute_time();
    is_game_running = true;
    while(is_game_running)
    {
        platform_input.dt_per_frame = target_seconds_per_frame;
        macos_handle_event(app, window, &platform_input);

        // TODO(joon): check if the focued window is working properly
        b32 is_window_focused = [app keyWindow] && [app mainWindow];

        /*
            TODO(joon) : For more precisely timed rendering, the operations should be done in this order
            1. Update the game based on the input
            2. Check the mach absolute time
            3. With the return value from the displayLinkOutputCallback function, get the absolute time to present
            4. Use presentDrawable:atTime to present at the specific time
        */

        // TODO(joon) : last permission bit should not matter, but double_check?
        int lock_file = open(lock_file_path, O_RDONLY); 
        if(lock_file < 0)
        {
            if(macos_get_last_modified_time(game_code_path) != macos_game_code.last_modified_time)
            {
                macos_load_game_code(&macos_game_code, game_code_path);
            }
        }
        else
        {
            close(lock_file);
        }

        if(macos_game_code.update_and_render)
        {
            macos_game_code.update_and_render(&platform_api, &platform_input, &platform_memory, &platform_render_push_buffer);
        }

        u64 time_passed_in_nano_seconds = mach_time_diff_in_nano_seconds(last_time, mach_absolute_time(), nano_seconds_per_tick);

        // NOTE(joon): Because nanosleep is such a high resolution sleep method, for precise timing,
        // we need to undersleep and spend time in a loop
        u64 undersleep_nano_seconds = 100000000;
        if(time_passed_in_nano_seconds < target_nano_seconds_per_frame)
        {
            timespec time_spec = {};
            time_spec.tv_nsec = target_nano_seconds_per_frame - time_passed_in_nano_seconds -  undersleep_nano_seconds;

            nanosleep(&time_spec, 0);
        }
        else
        {
            // TODO : Missed Frame!
            // TODO(joon) : Whenever we miss the frame re-sync with the display link
        }

        // For a short period of time, loop
        time_passed_in_nano_seconds = mach_time_diff_in_nano_seconds(last_time, mach_absolute_time(), nano_seconds_per_tick);
        while(time_passed_in_nano_seconds < target_nano_seconds_per_frame)
        {
            time_passed_in_nano_seconds = mach_time_diff_in_nano_seconds(last_time, mach_absolute_time(), nano_seconds_per_tick);
        }
        u32 time_passed_in_micro_sec = (u32)(time_passed_in_nano_seconds / 1000);
        f32 time_passed_in_sec = (f32)time_passed_in_micro_sec / 1000000.0f;
        printf("%dms elapsed, fps : %.6f\n", time_passed_in_micro_sec, 1.0f/time_passed_in_sec);
        @autoreleasepool
        {
            metal_render_and_display(&metal_render_context, &platform_render_push_buffer, window_width, window_height);
        }

#if 0
        // NOTE(joon) : debug_printf_all_cycle_counters
        for(u32 cycle_counter_index = 0;
                cycle_counter_index < debug_cycle_counter_count;
                cycle_counter_index++)
        {
            printf("ID:%u  Total Cycles: %llu Hit Count: %u, CyclesPerHit: %u\n", cycle_counter_index, 
                                                                             debug_cycle_counters[cycle_counter_index].cycle_count,
                                                                            debug_cycle_counters[cycle_counter_index].hit_count, 
                                                                            (u32)(debug_cycle_counters[cycle_counter_index].cycle_count/debug_cycle_counters[cycle_counter_index].hit_count));
        }
#endif

        // update the time stamp
        last_time = mach_absolute_time();
    }

    return 0;
}











