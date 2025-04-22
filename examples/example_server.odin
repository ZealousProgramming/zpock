package examples

import "core:mem"
import "core:log"
import fmt "core:fmt"

import "../"

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	context.logger = log.create_console_logger(log.Level.Debug)

	// Actual demo
	{
		server, successful := zpock.server_init("127.0.0.1", 5808)
		if !successful {
			return
		}
		defer zpock.server_destroy(server)

		zpock.on(server, "connect", on_connect)
		zpock.on(server, "disconnect", on_disconnect)
	    
	    // TODO(devon): Figure out build/send packet api
	    // zpock.send()

	    for {
	    	zpock.poll(server)
	    }
	}

	log.destroy_console_logger(context.logger)

	for _, leak in track.allocation_map {
		fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
	}

	for bad_free in track.bad_free_array {
		fmt.printf(
			"%p allocation %p was freed incorrectly\n",
			bad_free.location,
			bad_free.memory,
		)
	}
}

@(private ="file")
on_connect :: proc() {
	log.info("Connection to the server successful")
}

@(private ="file")
on_disconnect :: proc() {
	log.info("Diconnection from the server successful")
}