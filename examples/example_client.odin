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
		client, successful := zpock.client_init("127.0.0.1", 5808)
		if !successful {
			return
		}
		defer zpock.client_destroy(client)

		zpock.client_on(client, "connect", on_connect)
		zpock.client_on(client, "disconnect", on_disconnect)
	    
	    successful = zpock.connect(client)
	    if !successful {
	    	return
	    }
	    // zpock.send()
	    
	    // TODO(devon): Figure out build/send packet api
		for {
	    	zpock.client_poll(client)
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