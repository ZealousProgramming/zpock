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
		server, successful := zpock.server_init("127.0.0.1", 5808)
		if !successful {
			return
		}
		defer zpock.server_destroy(server)

		zpock.on(server, "connect", on_connect)
		zpock.on(server, "disconnect", on_disconnect)

		for {
			zpock.poll(server)
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
on_connect :: proc(host: ^zpock.Host, peer: ^zpock.Peer) {
	log.infof(
		"New client has connected to the server from.. %v:%v\n",
		peer.address.host,
		peer.address.port,
	)

	response: string = "Hello gov'na, run from me my dude"
	packet_builder: zpock.Packet_Builder
	zpock.write_opcode(&packet_builder, zpock.Opcode(Ops.Hello))
	zpock.write_string(&packet_builder, &response)
	zpock.send_reliable(peer, &packet_builder)
}

@(private = "file")
on_disconnect :: proc(host: ^zpock.Host, peer: ^zpock.Peer) {
	log.info("Diconnection from the server successful")
}
