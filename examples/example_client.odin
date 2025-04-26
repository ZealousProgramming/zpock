package examples

import fmt "core:fmt"
import "core:log"
import "core:mem"

import "../"

@(private = "file")
Ops :: enum (zpock.Opcode) {
	Invalid,
	Hello,
}

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

		zpock.on(client, "connect", on_connect)
		zpock.on(client, "disconnect", on_disconnect)
		zpock.set_handler(client, zpock.Opcode(Ops.Hello), hello_handler)

		successful = zpock.connect(client)
		if !successful {
			return
		}
		defer zpock.disconnect(client)

		for {
			zpock.poll(client)
		}
	}

	log.destroy_console_logger(context.logger)

	for _, leak in track.allocation_map {
		fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
	}

	for bad_free in track.bad_free_array {
		fmt.printf("%p allocation %p was freed incorrectly\n", bad_free.location, bad_free.memory)
	}
}

@(private = "file")
on_connect :: proc() {
	log.info("Connection to the server successful")
}

@(private = "file")
on_disconnect :: proc() {
	log.info("Diconnection from the server successful")
}

@(private = "file")
hello_handler :: proc(peer: ^zpock.Peer, reader: ^zpock.Packet_Reader, allocator := context.allocator) {
	message, _ := zpock.read_string(reader, .Little, context.temp_allocator)

	log.infof("Recieved a message from the server: %v\n", message)
}