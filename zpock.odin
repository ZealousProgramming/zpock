package zpock

import "core:bytes"
import "core:encoding/endian"
import "core:log"
import "core:slice"
import "core:strings"
import net "vendor:ENet"

// Aliases 
// ---------------
Opcode :: u16be
Packet :: net.Packet
Peer :: net.Peer
Packet_Builder :: bytes.Buffer
Packet_Handler :: #type proc(reader: ^Packet_Reader, packet: ^Packet)

Callback :: union {
	#type proc(),
	#type proc(host: ^Host, peer: ^Peer),
}

Packet_Reader :: struct {
	offset: uint,
	length: uint,
	data: [^]byte,
}

Host :: struct {
	host:     ^net.Host,
	hostname: cstring,
	port:     u16,
	events:   map[string]Callback,
	handlers: map[Opcode]Packet_Handler,
}

Client :: struct {
	// Yuck Yuck Yuck - spit spit
	using _:        Host,
	server_peer:    ^Peer,
	server_address: net.Address,
}

Server :: struct {
	// Yuck Yuck Yuck - spit spit
	using _: Host,
	address: net.Address,
}

Connection_Options :: struct {
	max_connections:    uint,
	channel_limit:      uint,
	incoming_bandwith:  u32,
	outgoing_bandwith:  u32,
	connect_timeout:    u32,
	disconnect_timeout: u32,
	poll_timeout:       u32,
	blocking:           bool,
}

client_init :: proc(
	hostname: string,
	port: u16,
	options := DEFAULT_CLIENT_CONNECTION_OPTIONS,
	allocator := context.allocator,
) -> (
	^Client,
	bool,
) {
	// Initialize ENet
	if err := net.initialize(); err != 0 {
		log.errorf("ENet failed to initialize: %v\n", err)

		return nil, false
	}

	// Create client host
	host := net.host_create(
		nil,
		options.max_connections,
		options.channel_limit,
		options.incoming_bandwith,
		options.outgoing_bandwith,
	)
	if host == nil {
		log.error("ENet failed to create client host\n")

		return nil, false
	}

	client := new(Client, allocator)
	client.host = host
	client.hostname = strings.clone_to_cstring(hostname, allocator)
	client.port = port

	client.handlers = make(map[Opcode]Packet_Handler, allocator)

	return client, true
}

client_destroy :: proc(client: ^Client, allocator := context.allocator) {
	if client == nil {return}
	if client.hostname != nil {
		delete(client.hostname, allocator)
	}

	// Clean up for ENet
	net.host_destroy(client.host)
	net.deinitialize()

	delete(client.handlers)

	free(client, allocator)
}


server_init :: proc(
	hostname: string,
	port: u16,
	options := DEFAULT_CONNECTION_OPTIONS,
	allocator := context.allocator,
) -> (
	^Server,
	bool,
) {
	// Initialize ENet
	if err := net.initialize(); err != 0 {
		log.errorf("ENet failed to initialize: %v\n", err)

		return nil, false
	}

	server := new(Server, allocator)
	server.port = port
	server.hostname = strings.clone_to_cstring(hostname, allocator)

	net.address_set_host(&server.address, server.hostname)
	server.address.port = port

	// Create server host
	host := net.host_create(
		&server.address,
		options.max_connections,
		options.channel_limit,
		options.incoming_bandwith,
		options.outgoing_bandwith,
	)
	if host == nil {
		log.error("ENet failed to create client host\n")
		delete(server.hostname, allocator)
		free(server, allocator)
		return nil, false
	}

	server.host = host
	server.handlers = make(map[Opcode]Packet_Handler, allocator)

	log.infof("Server is listening on %v:%v...\n", hostname, port)

	return server, true
}

server_destroy :: proc(server: ^Server, allocator := context.allocator) {
	if server == nil {return}
	if server.hostname != nil {
		delete(server.hostname, allocator)
	}

	// Clean up for ENet
	net.host_destroy(server.host)
	net.deinitialize()

	delete(server.handlers)

	free(server, allocator)
}

connect :: proc(
	client: ^Client,
	timeout := DEFAULT_CLIENT_CONNECTION_OPTIONS.connect_timeout,
	blocking := DEFAULT_CONNECTION_OPTIONS.blocking,
) -> bool {
	net.address_set_host(&client.server_address, client.hostname)
	client.server_address.port = client.port

	log.infof("Client attempting to connect to %v:%v\n", client.hostname, client.port)
	server := net.host_connect(client.host, &client.server_address, 1, 0)
	if server == nil {
		log.errorf("Client failed to connect to %v:%v\n", client.hostname, client.port)
		return false
	}

	log.debugf("timeout: %v\n", timeout)
	log.debugf("blocking: %v\n", blocking)

	event: net.Event
	// Validate connection through a connection event
	if net.host_service(client.host, &event, timeout) > 0 && event.type == .CONNECT {
		log.infof(
			"Client connect to %v:%v successfully established\n",
			client.hostname,
			client.port,
		)
	} else {
		log.error(event)
		log.errorf(
			"Client failed to receive a connection event from %v:%v\n",
			client.hostname,
			client.port,
		)
		net.peer_reset(server)

		return false
	}

	// If the connection should be non-blocking, make sure to set it in the socket
	if !blocking {
		log.info("Client requested the socket to be non-blocking")
		blocking_result := net.socket_set_option(server.host.socket, .NONBLOCK, 1)

		if blocking_result != 0 {
			log.errorf("Failed to set socket to be non-blocking: %v\n", blocking_result)

			return false
		}
	}

	client.server_peer = server
	return true
}

disconnect :: proc(
	client: ^Client,
	timeout := DEFAULT_CLIENT_CONNECTION_OPTIONS.disconnect_timeout,
) -> bool {
	net.peer_disconnect(client.server_peer, 0)

	successful := false

	event: net.Event
	for net.host_service(client.host, &event, timeout) > 0 {
		#partial switch event.type {
		case .DISCONNECT:
			{
				log.infof("Client successfully disconnected from server")
				successful = true
			}
		case:
			{

			}
		}
	}

	return successful
}

on :: proc(host: ^Host, event_name: string, callback: Callback, overwrite := false) -> bool {
	if host == nil {return false}

	if event_name in host.events {
		if !overwrite {
			log.errorf(
				"Event '%v' already has a registered callback, if this was intended, please provide the 'overwrite' flag to the 'on' procedure call\n",
				event_name,
			)
			return false
		}
	}

	log.infof("Callback registered for event '%v'\n", event_name)
	host.events[event_name] = callback

	return true
}

poll :: proc(
	host: ^Host,
	poll_timeout := DEFAULT_CONNECTION_OPTIONS.poll_timeout,
	allocator := context.allocator,
) {
	if host == nil {return}

	event: net.Event

	for net.host_service(host.host, &event, poll_timeout) > 0 {
		switch event.type {
		case .CONNECT:
			{
				log.infof(
					"A new client connected from %v:%v\n",
					event.peer.address.host,
					event.peer.address.port,
				)

				if "connect" in host.events {
					connect := host.events["connect"].(proc(host: ^Host, peer: ^Peer))
					connect(host, event.peer)
				}
			}
		case .DISCONNECT:
			{
				log.infof("A client disconnect_timeout: %v\n", event.peer.data)

				if "disconnect" in host.events {
					disconnect := host.events["disconnect"].(proc(host: ^Host, peer: ^Peer))
					disconnect(host, event.peer)
				}

				event.peer.data = nil
			}
		case .NONE:
			{
				log.warnf("A typeless event recieved: %v\n", event)
			}
		case .RECEIVE:
			{
				log.debugf(
					"A packet of length %v containing %v was received from %v:%v on channel %v.\n",
					event.packet.dataLength,
					event.packet.data,
					event.peer.address.host,
					event.peer.address.port,
					event.channelID,
				)

				defer net.packet_destroy(event.packet)

				reader: Packet_Reader = {data = event.packet.data, length = event.packet.dataLength}

				opcode, opcode_success := read_opcode(&reader)
				if !opcode_success {
					log.errorf("Failed to read opcode from packet: %v\n", event.packet)
				}

				if opcode not_in host.handlers {
					log.errorf("No Opcode Handler registered for: %v..\n", opcode)

					return
				}

				host.handlers[opcode](&reader, event.packet)
			}
		}
	}
}

set_handler :: proc(host: ^Host, opcode: Opcode, handler: Packet_Handler) {
	if host == nil {return}
	if handler == nil {return}

	log.debugf("Packet handler registered for opcode: %v\n", opcode)
	host.handlers[opcode] = handler
}

send :: proc {
	send_message,
	send_packet,
	send_packet_builder,
	client_send_message,
}

send_reliable :: proc {
	send_message_reliable,
	send_packet_reliable,
	send_packet_builder_reliable,
	client_send_message_reliable,
}

client_send_message_reliable :: proc(client: ^Client, message: string, channel_id: u8 = 0) {
	client_send_message(client, message, true, channel_id)
}
client_send_message :: proc(
	client: ^Client,
	message: string,
	reliable: bool = false,
	channel_id: u8 = 0,
) {
	send_message(client.server_peer, message, reliable, channel_id)
}

send_message_reliable :: proc(peer: ^Peer, message: string, channel_id: u8 = 0) {
	send_message(peer, message, true, channel_id)
}

send_message :: proc(peer: ^Peer, message: string, reliable: bool = false, channel_id: u8 = 0) {
	flags: net.PacketFlags
	if reliable {
		flags += {.RELIABLE}
	}

	packet := net.packet_create(raw_data(message), size_of(u8) * len(message), flags)

	if packet == nil {
		log.warnf("Failed to create packet of size %v\n", size_of(message))
		return
	}

	err := net.peer_send(peer, channel_id, packet)
	if err != 0 {
		log.errorf(
			"Failed to send packet to outgoingID(%v) incomingId(%v): %v\n",
			peer.outgoingPeerID,
			peer.incomingPeerID,
			err,
		)
		return
	}
}

send_packet_builder_reliable :: proc(peer: ^Peer, builder: ^Packet_Builder, channel_id: u8 = 0) {
	send_packet_builder(peer, builder, true, channel_id)
}

send_packet_builder :: proc(
	peer: ^Peer,
	builder: ^Packet_Builder,
	reliable: bool = false,
	channel_id: u8 = 0,
) {
	data, success := to_bytes(builder)

	if !success {
		log.warn("Failed to fetch packet data..")

		return
	}

	send_packet(peer, data, reliable, channel_id)
}

send_packet_reliable :: proc(peer: ^Peer, packet: []byte, channel_id: u8 = 0) {
	send_packet(peer, packet, true, channel_id)
}

send_packet :: proc(peer: ^Peer, packet: []byte, reliable: bool = false, channel_id: u8 = 0) {
	flags: net.PacketFlags
	if reliable {
		flags += {.RELIABLE}
	}

	packet := net.packet_create(raw_data(packet), len(packet), flags)

	if packet == nil {
		log.warnf("Failed to create packet of size %v\n", size_of(packet))
		return
	}

	err := net.peer_send(peer, channel_id, packet)
	if err != 0 {
		log.errorf(
			"Failed to send packet to outgoingID(%v) incomingId(%v): %v\n",
			peer.outgoingPeerID,
			peer.incomingPeerID,
			err,
		)
		return
	}
}

packet_builder_destroy :: proc(builder: ^Packet_Builder, allocator := context.allocator) {
	delete(builder.buf)
}

to_bytes :: proc(builder: ^Packet_Builder) -> ([]byte, bool) {
	if builder == nil {
		log.warn("Builder is nil..\n")
		return nil, false
	}

	if len(builder.buf) <= 0 {
		log.warn("Builder buffer is empty..\n")
		return nil, false
	}

	b := bytes.buffer_to_bytes(builder)
	log.debugf("Packet buffer: %v bytes\n", len(b))

	return b, true
}

// Reads
read_opcode :: proc(reader: ^Packet_Reader, byte_order := endian.Byte_Order.Big) -> (u16be, bool) {
	if reader == nil || reader.length <= 0 {
		log.warnf("Packet data was nil or empty..")
		return 0, false
	}

	if reader.length - 2 < 0 {
		log.warnf("Invalid packet structure..")
		return 0, false
	}

	opcode, ok := endian.get_u16(reader.data[reader.offset:2], byte_order)

	if !ok {
		log.warnf("Failed to read opcode..")
		return 0, false
	}

	reader.offset += 2

	log.debugf("Recieved opcode: %v\n", u16be(opcode))

	return u16be(opcode), true
}

read_u16 :: proc(reader: ^Packet_Reader, byte_order := endian.Byte_Order.Big) -> (u16, bool) {
	size_u16: uint = size_of(u16)
	if reader == nil || reader.length <= 0 {
		log.warnf("Packet data was nil or empty..")
		return 0, false
	}

	if reader.offset + size_u16 >= reader.length {
		log.warnf("Not enough bytes to read..")
		return 0, false
	}

	value, ok := endian.get_u16(reader.data[reader.offset: reader.offset + size_u16], byte_order)

	if !ok {
		return 0, false
	}

	reader.offset += size_u16

	return value, true
}

read_i32 :: proc(reader: ^Packet_Reader, byte_order := endian.Byte_Order.Big) -> (i32, bool) {
	size_i32: uint = size_of(i32)

	if reader == nil || reader.length <= 0 {
		log.warnf("Packet data was nil or empty..")
		return 0, false
	}

	if reader.offset + size_i32 >= reader.length {
		log.warnf("Not enough bytes to read..")
		return 0, false
	}

	value, ok := endian.get_i32(reader.data[reader.offset : reader.offset + size_i32], byte_order)

	if !ok {
		log.debug("UHHHHH")
		return 0, false
	}

	reader.offset += size_i32

	return value, true
}

read_string :: proc(reader: ^Packet_Reader, byte_order := endian.Byte_Order.Big, allocator := context.allocator) -> (string, bool) {
	length, length_ok := read_i32(reader, byte_order)

	if !length_ok {
		return "", false
	}

	value, err := strings.clone_from_bytes(
		reader.data[reader.offset : reader.offset + uint(length)],
		allocator,
	)

	if err != nil {
		return "", false
	}

	reader.offset += uint(length)

	return value, true
}

// Writes
write_opcode :: proc(builder: ^Packet_Builder, data: u16be, allocator := context.allocator) {
	log.debugf("Writing Opcode: %v\n", data)

	bytes.buffer_write(builder, slice.to_bytes([]u16be{data}))
}

write_string :: proc(builder: ^Packet_Builder, data: ^string, allocator := context.allocator) {
	log.debugf("Writing String: %v (%v)\n", data^, len(data^))

	buff: [size_of(i32)]byte
	(cast(^i32)&buff)^ = i32(len(data^))

	bytes.buffer_write(builder, buff[:])
	bytes.buffer_write(builder, transmute([]u8)data^)
}


DEFAULT_CONNECTION_OPTIONS :: Connection_Options {
	max_connections    = 32,
	channel_limit      = 1,
	incoming_bandwith  = 0,
	outgoing_bandwith  = 0,
	connect_timeout    = 1000,
	disconnect_timeout = 1000,
	poll_timeout       = 1000,
	blocking           = false,
}

DEFAULT_CLIENT_CONNECTION_OPTIONS :: Connection_Options {
	max_connections    = 1,
	channel_limit      = 1,
	incoming_bandwith  = 0,
	outgoing_bandwith  = 0,
	connect_timeout    = 5000,
	disconnect_timeout = 1000,
	poll_timeout       = 1000,
	blocking           = false,
}
