# zpock
A wrapper around the networking library ENet for quick and easy use


``` go
// Ideal API for sending packets

// For single "message" packets
zpock.send(client, "yadda")

// Setting a custom serializer
zpock.set_serializer(client, serialize_func, deserialize_func)
zpock.set_serialize(client, serialize_func)
zpock.set_deserialize(client, deserialize_func)

some_obj: Some_Object
zpock.send(client, some_obj)

// Packet building for multiple "messages"
packet := zpock.packet()
zpock.packet_append(&packet, header_one, value_one)
zpock.packet_append(&packet, header_two, value_two)
zpock.build() // Do I need this?

zpock.send(client, &packet)
```