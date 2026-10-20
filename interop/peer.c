/* Independent peer: all XRCE framing and CDR encoding use eProsima's SDK. */
#include <uxr/client/client.h>
#include <ucdr/microcdr.h>
#include <stdio.h>
#include <stdlib.h>

static void expect_status(uxrSession *s, uint16_t request, uint8_t expected)
{
    uint8_t status = 0xff;
    (void)uxr_run_session_until_all_status(s, 2000, &request, &status, 1);
    if (status != expected) {
        fprintf(stderr, "request %u: expected status %u, got %u\n", request, expected, status);
        exit(1);
    }
}

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    uxrUDPTransport transport;
    if (!uxr_init_udp_transport(&transport, UXR_IPv4, "127.0.0.1", argv[1])) return 1;
    uxrSession session;
    uxr_init_session(&session, &transport.comm, 0x12345678);
    if (!uxr_create_session(&session)) {
        fprintf(stderr, "CREATE_CLIENT failed\n");
        return 1;
    }
    puts("SESSION OK"); fflush(stdout);
    /* One request per best-effort datagram; no reliable-stream claims. */
    uint8_t output[512];
    uxrStreamId stream = uxr_create_output_best_effort_stream(&session, output, sizeof(output));
    uxr_create_input_best_effort_stream(&session);
    uxrObjectId participant = uxr_object_id(0x101, UXR_PARTICIPANT_ID);
    uxrObjectId topic = uxr_object_id(0x102, UXR_TOPIC_ID);
    uxrObjectId publisher = uxr_object_id(0x103, UXR_PUBLISHER_ID);
    uxrObjectId writer = uxr_object_id(0x105, UXR_DATAWRITER_ID);
    expect_status(&session, uxr_buffer_create_participant_ref(&session, stream, participant, 0,
        "MyLibrary::CounterParticipant", UXR_REPLACE), UXR_STATUS_OK);
    expect_status(&session, uxr_buffer_create_topic_ref(&session, stream, topic, participant,
        "MyLibrary::CounterStatusTopic", UXR_REPLACE), UXR_STATUS_OK);
    expect_status(&session, uxr_buffer_create_publisher_xml(&session, stream, publisher, participant,
        "", UXR_REPLACE), UXR_STATUS_OK);
    expect_status(&session, uxr_buffer_create_datawriter_ref(&session, stream, writer, publisher,
        "MyLibrary::CounterStatusWriter", UXR_REPLACE), UXR_STATUS_OK);
    puts("CREATE OK"); fflush(stdout);
    expect_status(&session, uxr_buffer_create_topic_ref(&session, stream, topic, participant,
        "MissingTopic", UXR_REPLACE), UXR_STATUS_ERR_UNKNOWN_REFERENCE);
    uint8_t data[64];
    ucdrBuffer cdr;
    ucdr_init_buffer(&cdr, data, sizeof(data));
    ucdr_serialize_uint32_t(&cdr, 42);
    ucdr_serialize_string(&cdr, "eprosima");
    ucdr_serialize_sequence_uint8_t(&cdr, (const uint8_t[]){1, 2, 3}, 3);
    expect_status(&session, uxr_buffer_topic(&session, stream, writer, data,
        ucdr_buffer_length(&cdr)), UXR_STATUS_OK);
    expect_status(&session, uxr_buffer_topic(&session, stream, writer, data, 1),
        UXR_STATUS_ERR_INVALID_DATA);
    puts("WRITE AND NEGATIVE CASES OK");
    /* DELETE is outside the supported subset; close the transport only. */
    uxr_close_udp_transport(&transport);
    return 0;
}
