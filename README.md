# zpock
A wrapper around the networking library ENet for quick and easy use


``` go
// Setting opcode handlers
zpock.set_handler(client, op_code, handler_func)

// Packet building for multiple segments of a packet
packet_builder: zpock.Packet_Builder
zpock.write_opcode(&packet_builder, opcode_one)
zpock.write_string(&packet_builder, &value)

zpock.send(client, zpock.to_bytes(&packet_builder))
// or
zpock.send(client, &packet_builder)
```