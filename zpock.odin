package zpock

import "core:log"
import "core:strings"
import net "vendor:ENet"

Zpock_Callback :: union {
	#type proc(),
}

Zpock_Host :: struct {
	host: ^net.Host,
	hostname: cstring,
	port: u16,

	events: map[string]Zpock_Callback,
}

Zpock_Client :: struct {
	// Yuck Yuck Yuck - spit spit
	using _:Zpock_Host,

	server_peer: ^net.Peer,
	server_address: net.Address,

}

Zpock_Server :: struct {
	// Yuck Yuck Yuck - spit spit
	using _: Zpock_Host,

	address: net.Address,
}

Zpock_Connection_Options :: struct {
	max_connections: uint,
	channel_limit: uint,
	incoming_bandwith: u32,
	outgoing_bandwith: u32,
	connect_timeout: u32,
	disconnect_timeout: u32,
	poll_timeout: u32,
	blocking: bool,
}

client_init :: proc(hostname: string, port: u16, options := DEFAULT_CLIENT_CONNECTION_OPTIONS, allocator := context.allocator) -> (^Zpock_Client, bool) {
	// Initialize ENet
	if err := net.initialize(); err != 0 {
		log.errorf("[zpock][client_init] ENet failed to initialize: %v\n", err)

		return nil, false
	}

	// Create client host
	host := net.host_create(nil, options.max_connections, options.channel_limit, options.incoming_bandwith, options.outgoing_bandwith)
	if host == nil { 
		log.error("[zpock][client_init] ENet failed to create client host\n")

		return nil, false
	}

	client := new(Zpock_Client, allocator)
	client.host = host
	client.hostname = strings.clone_to_cstring(hostname, allocator)
	client.port = port

	return client, true
}

client_destroy :: proc(client: ^Zpock_Client, allocator := context.allocator) {
	if client == nil { return }
	if client.hostname != nil {
		delete(client.hostname, allocator)
	}

	// Clean up for ENet
	net.host_destroy(client.host)
	net.deinitialize()

	free(client, allocator)
}


server_init :: proc(hostname: string, port: u16, options := DEFAULT_CONNECTION_OPTIONS, allocator := context.allocator) -> (^Zpock_Server, bool) {
	// Initialize ENet
	if err := net.initialize(); err != 0 {
		log.errorf("[zpock][server_init] ENet failed to initialize: %v\n", err)

		return nil, false
	}

	server := new(Zpock_Server, allocator)
	server.port = port
	server.hostname = strings.clone_to_cstring(hostname, allocator)

	net.address_set_host(&server.address, server.hostname)
	server.address.port = port

	// Create server host
	host :=  net.host_create(&server.address, options.max_connections, options.channel_limit, options.incoming_bandwith, options.outgoing_bandwith)
	if host == nil { 
		log.error("[zpock][client_init] ENet failed to create client host\n")
		delete(server.hostname, allocator)
		free(server, allocator)
		return nil, false
	}

	server.host = host

	log.infof("[zpock][server_init] Server is listening on %v:%v...\n", hostname, port)

	return server, true
	// return nil, false
}

server_destroy :: proc(server: ^Zpock_Server, allocator := context.allocator) {
	if server == nil { return }
	if server.hostname != nil {
		delete(server.hostname, allocator)
	}

	// Clean up for ENet
	net.host_destroy(server.host)
	net.deinitialize()

	free(server, allocator)
}

connect :: proc(client: ^Zpock_Client, timeout := DEFAULT_CLIENT_CONNECTION_OPTIONS.connect_timeout, blocking := DEFAULT_CONNECTION_OPTIONS.blocking) -> bool {
	net.address_set_host(&client.server_address, client.hostname)
	client.server_address.port = client.port

	log.infof("[zpock][connect] Client attempting to connect to %v:%v\n", client.hostname, client.port)
	server := net.host_connect(client.host, &client.server_address, 1, 0)
	if server == nil {
		log.errorf("[zpock][connect] Client failed to connect to %v:%v\n", client.hostname, client.port)
		return false
	}

	log.debugf("[zpock][connect] timeout: %v\n", timeout)
	log.debugf("[zpock][connect] blocking: %v\n", blocking)

	event: net.Event
	// Validate connection through a connection event
	if net.host_service(client.host, &event, timeout) > 0 && event.type == .CONNECT {
		log.infof("[zpock][connect] Client connect to %v:%v successfully established\n", client.hostname, client.port)
	} else {
		log.error(event)
		log.errorf("[zpock][connect] Client failed to receive a connection event from %v:%v\n", client.hostname, client.port)
		net.peer_reset(server)

		return false
	}

	// If the connection should be non-blocking, make sure to set it in the socket
	if !blocking {
		log.info("[zpock][connect] Client requested the socket to be non-blocking")
		blocking_result := net.socket_set_option(server.host.socket, .NONBLOCK, 1)

		if blocking_result != 0 {
			log.errorf("[zpock][connect] Failed to set socket to be non-blocking: %v\n", blocking_result)

			return false
		}
	}

	client.server_peer = server
	return true
}

disconnect :: proc(client: ^Zpock_Client, timeout := DEFAULT_CLIENT_CONNECTION_OPTIONS.disconnect_timeout) -> bool{
	net.peer_disconnect(client.server_peer, 0)

	successful := false

	event: net.Event
	for net.host_service(client.host, &event, timeout) > 0 {
		#partial switch event.type {
		case .DISCONNECT: {
			log.infof("[zpock][disconnect] Client successfully disconnected from server")
			successful = true
		}
		case: {

		}
		}
	}

	return successful
}

on :: proc(host: ^Zpock_Host, event_name: string, callback: Zpock_Callback, overwrite := false) -> bool {
	if host == nil { return false }

	if event_name in host.events {
		if !overwrite {
			log.errorf("[zpock][on] Event '%v' already has a registered callback, if this was intended, please provide the 'overwrite' flag to the 'on' procedure call\n", event_name)
			return false
		}
	}

	log.infof("[zpock][on] Callback registered for event '%v'\n", event_name)
	host.events[event_name] = callback

	return true
}

poll :: proc(host: ^Zpock_Host, poll_timeout := DEFAULT_CONNECTION_OPTIONS.poll_timeout, allocator := context.allocator) {
	if host == nil { return }

	event: net.Event

	for net.host_service(host.host, &event, poll_timeout) > 0 {
		switch event.type {
		case .CONNECT: {
			log.infof("[zpock][poll] A new client connected from %v:%v\n", event.peer.address.host, event.peer.address.port)

			if "connect" in host.events {
				connect := host.events["connect"].(proc())
				connect()
			}
		}
		case .DISCONNECT: {
			log.infof("[zpock][poll] A client disconnect_timeout: %v\n", event.peer.data)

			if "disconnect" in host.events {
				disconnect := host.events["disconnect"].(proc())
				disconnect()
			}
			
			event.peer.data = nil
		}
		case .NONE: {
			log.warnf("[zpock][poll] A typeless event recieved: %v\n", event)	
		}
		case .RECEIVE: {
			log.debugf(
				"A packet of length %v containing %v was received from %v:%v on channel %v.\n",
				event.packet.dataLength,
				event.packet.data,
				event.peer.address.host,
				event.peer.address.port,
				event.channelID,
			)

			defer net.packet_destroy(event.packet)

			content, _ := strings.clone_from_bytes(event.packet.data[:event.packet.dataLength], context.temp_allocator) 
			log.info(content)
			log.info("\n")
		}
		}
	}
}

send :: proc {
	send_message,
	client_send_message,
}

client_send_message :: proc(client: ^Zpock_Client, message:string, reliable: bool = false, channel_id: u8 = 0) {
	send_message(client.server_peer, message, reliable, channel_id)
}

send_message :: proc (peer: ^net.Peer, message: string, reliable: bool = false, channel_id: u8 = 0) {
	flags: net.PacketFlags
	if reliable {
		flags += {.RELIABLE}
	}

	packet := net.packet_create(raw_data(message), size_of(u8) * len(message), flags)

	if packet == nil {
		log.warnf("[zpock][send_message] Failed to create packet of size %v\n", size_of(message))
		return 
	}

	err := net.peer_send(peer, channel_id, packet)
	if err != 0 {
		log.errorf("[zpock][send_message] Failed to send packet to outgoingID(%v) incomingId(%v): %v\n", peer.outgoingPeerID, peer.incomingPeerID, err)
		return 
	}
}


// 
DEFAULT_CONNECTION_OPTIONS :: Zpock_Connection_Options {
	max_connections = 32,
	channel_limit = 1,
	incoming_bandwith = 0,
	outgoing_bandwith = 0,
	connect_timeout = 1000,
	disconnect_timeout = 1000,
	poll_timeout = 1000,
	blocking = false,
}

DEFAULT_CLIENT_CONNECTION_OPTIONS :: Zpock_Connection_Options {
	max_connections = 1,
	channel_limit = 1,
	incoming_bandwith = 0,
	outgoing_bandwith = 0,
	connect_timeout = 5000,
	disconnect_timeout = 1000,
	poll_timeout = 1000,
	blocking = false,
}
