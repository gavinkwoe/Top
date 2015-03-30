//
//   _____    ___    ___
//  /__   \  /___\  / _ \
//   / /\/  //  // / /_)/
//  / /    / \_// / ___/
//  \/     \___/  \/
//
//	Only for fun :-)
//

#import "top.h"

#import <stdio.h>
#import <stdlib.h>
#import <stdint.h>
#import <string.h>
#import <assert.h>
#import <errno.h>

#import <sys/errno.h>
#import <sys/sockio.h>
#import <sys/ioctl.h>
#import <sys/types.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/mman.h>

#import <math.h>
#import <unistd.h>
#import <limits.h>
#import <execinfo.h>

#import <netdb.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <netinet/in.h>
#import <netinet6/in6.h>
#import <arpa/inet.h>
#import <ifaddrs.h>

#import <mach/mach.h>
#import <mach/machine.h>
#import <machine/endian.h>
#import <malloc/malloc.h>

#import <sys/utsname.h>

#import <fcntl.h>
#import <dirent.h>
#import <dlfcn.h>

#import <mach-o/fat.h>
#import <mach-o/dyld.h>
#import <mach-o/arch.h>
#import <mach-o/nlist.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>

#import <zlib.h>
//#import <libxml2/libxml/HTMLparser.h>
//#import <libxml2/libxml/tree.h>
//#import <libxml2/libxml/xpath.h>

#ifdef __IPHONE_8_0
#import <spawn.h>
#endif

#ifdef __OBJC__

#import <Availability.h>
#import <Foundation/Foundation.h>

#if (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)

#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <TargetConditionals.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <SystemConfiguration/SystemConfiguration.h>

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>
#import <CoreLocation/CoreLocation.h>

#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#else	// #if (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)

#import <Cocoa/Cocoa.h>
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

#import <objc/objc-class.h>

#endif	// #if (TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR)

#import <CommonCrypto/CommonDigest.h>

#endif	// #ifdef __OBJC__

// ----------------------------------
// Source code
// ----------------------------------

#pragma mark -

#undef	MAX_TOP_FPS
#define MAX_TOP_FPS			(2)

#undef	MAX_TOP_THREADS
#define MAX_TOP_THREADS		(64)

#undef	MAX_TOP_SNAPSHOTS
#define MAX_TOP_SNAPSHOTS	(16)

#pragma mark -

typedef struct
{
	float						percent;
	long						sec;
	long						usec;
	
	unsigned int				threadCount;
	struct thread_basic_info	threads[MAX_TOP_THREADS + 1];
} TopCPUSnapshot;

typedef struct
{
	unsigned int				snapshotCount;
	TopCPUSnapshot				snapshots[MAX_TOP_SNAPSHOTS + 1];
} TopCPU;

typedef struct
{
	float						percent;
	natural_t					used;
	natural_t					free;
	natural_t					total;

	struct vm_statistics		vm_stat;
	struct task_basic_info		task_info;
} TopMemSnapshot;

typedef struct
{
	unsigned int				snapshotCount;
	TopMemSnapshot				snapshots[MAX_TOP_SNAPSHOTS + 1];
} TopMem;

typedef struct
{
	TopCPU						cpu;
	TopMem						mem;
} TopInfo;

#pragma mark -

static TopInfo * TopInfo_new( void )
{
	TopInfo * info = (TopInfo *)malloc( sizeof(TopInfo) );
	memset( info, 0x0, sizeof(TopInfo) );
	return info;
}

static void TopInfo_delete( TopInfo * info )
{
	free( info );
}

static void TopInfo_shift( TopInfo * info )
{
	if ( info->mem.snapshotCount && info->mem.snapshotCount >= MAX_TOP_SNAPSHOTS )
	{
		memcpy( (void *)&(info->mem.snapshots[0]), (void *)&(info->mem.snapshots[1]), sizeof(TopMemSnapshot) * MAX_TOP_SNAPSHOTS );
		
		info->mem.snapshotCount -= 1;
	}

	if ( info->cpu.snapshotCount && info->cpu.snapshotCount >= MAX_TOP_SNAPSHOTS )
	{
		memcpy( (void *)&(info->cpu.snapshots[0]), (void *)&(info->cpu.snapshots[1]), sizeof(TopCPUSnapshot) * MAX_TOP_SNAPSHOTS );
		
		info->cpu.snapshotCount -= 1;
	}
}

static void TopInfo_update( TopInfo * info )
{
	if ( info->mem.snapshotCount < MAX_TOP_SNAPSHOTS )
	{
		TopMemSnapshot * snapshot = &info->mem.snapshots[info->mem.snapshotCount];

		mach_port_t host_port;
		mach_msg_type_number_t host_size;
		vm_size_t pagesize;
		
		host_port = mach_host_self();
		host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
		host_page_size( host_port, &pagesize );
		
		kern_return_t ret = host_statistics( host_port, HOST_VM_INFO, (host_info_t)&(snapshot->vm_stat), &host_size );
		if ( KERN_SUCCESS == ret )
		{
			snapshot->used = (snapshot->vm_stat.active_count + snapshot->vm_stat.inactive_count + snapshot->vm_stat.wire_count) * pagesize;
			snapshot->free = snapshot->vm_stat.free_count * pagesize;
			snapshot->total = snapshot->used + snapshot->free;
			
			snapshot->percent = (float)snapshot->used / (float)snapshot->total;
			
			info->mem.snapshotCount += 1;
		}
	}
	
	if ( info->cpu.snapshotCount < MAX_TOP_SNAPSHOTS )
	{
		TopCPUSnapshot * snapshot = &info->cpu.snapshots[info->cpu.snapshotCount];

		kern_return_t			kr = { 0 };
		task_info_data_t		tinfo = { 0 };
		mach_msg_type_number_t	task_info_count = TASK_INFO_MAX;
		
		kr = task_info( mach_task_self(), TASK_BASIC_INFO, (task_info_t)tinfo, &task_info_count );
		if ( KERN_SUCCESS == kr )
		{
			task_basic_info_t		basic_info = { 0 };
			thread_array_t			thread_list = { 0 };
			mach_msg_type_number_t	thread_count = { 0 };
			
			thread_info_data_t		thinfo = { 0 };
			thread_basic_info_t		basic_info_th = { 0 };
			
			basic_info = (task_basic_info_t)tinfo;
			
			// get threads in the task
			kr = task_threads( mach_task_self(), &thread_list, &thread_count );
			if ( KERN_SUCCESS == kr )
			{
				long	tot_sec = 0;
				long	tot_usec = 0;
				float	tot_cpu = 0;

				snapshot->threadCount = thread_count;
				
				for ( unsigned int i = 0; i < thread_count; i++ )
				{
					mach_msg_type_number_t thread_info_count = THREAD_INFO_MAX;
					
					kr = thread_info( thread_list[i], THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count );
					if ( KERN_SUCCESS == kr )
					{
						basic_info_th = (thread_basic_info_t)thinfo;
						
						if ( 0 == (basic_info_th->flags & TH_FLAGS_IDLE) )
						{
							tot_sec		= tot_sec + basic_info_th->user_time.seconds + basic_info_th->system_time.seconds;
							tot_usec	= tot_usec + basic_info_th->system_time.microseconds + basic_info_th->system_time.microseconds;
							tot_cpu		= tot_cpu + basic_info_th->cpu_usage / (float)TH_USAGE_SCALE;
						}
						
						memcpy( (void *)&(snapshot->threads[i]), (void *)&basic_info_th, sizeof(thread_basic_info_t) );
					}
				}

				kr = vm_deallocate( mach_task_self(), (vm_offset_t)thread_list, thread_count * sizeof(thread_t) );
				if ( KERN_SUCCESS == kr )
				{
					snapshot->sec = tot_sec;
					snapshot->usec = tot_usec;
					snapshot->percent = tot_cpu;
					
					info->cpu.snapshotCount += 1;
				}
			}
		}
	}
}

#pragma mark -

@implementation Top
{
	NSTimer *		_timer;
	TopInfo *		_info;
}

+ (void)load
{
	static dispatch_once_t	once;
	static Top *			instance;
	
	dispatch_once( &once, ^{ instance = [[Top alloc] init]; });
}

- (id)init
{
	self = [super init];
	if ( self )
	{
		_timer = [NSTimer scheduledTimerWithTimeInterval:(1.0f / (MAX_TOP_FPS * 1.0f))
												  target:self
												selector:@selector(didTimeout)
												userInfo:nil
												 repeats:YES];

		_info = TopInfo_new();
	}
	return self;
}

- (void)dealloc
{
	TopInfo_delete( _info );
	_info = NULL;
	
	[_timer invalidate];
	_timer = nil;
}

- (void)didTimeout
{
	[self update];
	[self render];
}

- (void)update
{
	TopInfo_shift( _info );
	TopInfo_update( _info );
}

- (void)render
{
//	for ( unsigned int i = 0; i < _info->mem.snapshotCount; ++i )
//	{
//		TopMemSnapshot * snapshot = &_info->mem.snapshots[i];
//		
//		
//		
//	}
//	
//	if ( _info->mem.snapshotCount )
//	{
//		TopCPUSnapshot * snapshot = &info->cpu.snapshots[info->cpu.snapshotCount];
//
//	}

//	▅▂▅▂▄▅▂▁▂▄▅▂▅▂▂▄▁▂▄▅█▄▅▂▁▂▄▅▂▅██████▄▅▅▂▂▄▅▂▁▂▄▅▂▁▂▄▅▂▅▂▂▄

	fprintf( stderr, "   " );
	
	if ( _info->mem.snapshotCount )
	{
		TopMemSnapshot * lastSnapshot = &_info->mem.snapshots[_info->mem.snapshotCount - 1];

		fprintf( stderr, "MEM (%4dM / %4dM) [", lastSnapshot->used / 1024 / 1024, lastSnapshot->total / 1024 / 1024 );

		for ( unsigned int i = 0; i < MAX_TOP_SNAPSHOTS; ++i )
		{
			if ( i < _info->mem.snapshotCount )
			{
				TopMemSnapshot * snapshot = &_info->mem.snapshots[i];

				if ( snapshot->percent <= 0.0f )
				{
					fprintf( stderr, "_" );
				}
				else if ( snapshot->percent <= 0.25f )
				{
					fprintf( stderr, "▂" );
				}
				else if ( snapshot->percent <= 0.5f )
				{
					fprintf( stderr, "▄" );
				}
				else if ( snapshot->percent <= 0.75f )
				{
					fprintf( stderr, "▅" );
				}
				else
				{
					fprintf( stderr, "█" );
				}
			}
			else
			{
				fprintf( stderr, "_" );
			}
		}
		
		fprintf( stderr, " %.1f%%]", lastSnapshot->percent * 100 );
	}
	
	fprintf( stderr, "   " );

	if ( _info->cpu.snapshotCount )
	{
		TopCPUSnapshot * lastSnapshot = &_info->cpu.snapshots[_info->cpu.snapshotCount - 1];
		
		fprintf( stderr, "CPU (%d threads) [", lastSnapshot->threadCount );
		
		for ( unsigned int i = 0; i < MAX_TOP_SNAPSHOTS; ++i )
		{
			if ( i < _info->cpu.snapshotCount )
			{
				TopCPUSnapshot * snapshot = &_info->cpu.snapshots[i];
				
				if ( snapshot->percent <= 0.0f )
				{
					fprintf( stderr, "_" );
				}
				else if ( snapshot->percent <= 0.25f )
				{
					fprintf( stderr, "▂" );
				}
				else if ( snapshot->percent <= 0.5f )
				{
					fprintf( stderr, "▄" );
				}
				else if ( snapshot->percent <= 0.75f )
				{
					fprintf( stderr, "▅" );
				}
				else
				{
					fprintf( stderr, "█" );
				}
			}
			else
			{
				fprintf( stderr, "_" );
			}
		}
		
		fprintf( stderr, " %.1f%%]", lastSnapshot->percent * 100 );
	}

	fprintf( stderr, "\n" );
}

@end

