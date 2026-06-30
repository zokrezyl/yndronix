/* dnstest -- exercise getaddrinfo()/freeaddrinfo() (to verify the ynss DNS
 * shim). Prints each resolved address for the given host. */
#include <stdio.h>
#include <string.h>
#include <netdb.h>
#include <netinet/in.h>
#include <arpa/inet.h>

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: dnstest <hostname>\n");
        return 2;
    }
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *result = NULL;
    int rc = getaddrinfo(argv[1], NULL, &hints, &result);
    if (rc != 0) {
        printf("getaddrinfo(%s) FAILED: %s\n", argv[1], gai_strerror(rc));
        return 1;
    }
    for (struct addrinfo *entry = result; entry != NULL; entry = entry->ai_next) {
        char text[64] = {0};
        void *addr = (entry->ai_family == AF_INET)
            ? (void *)&((struct sockaddr_in *)entry->ai_addr)->sin_addr
            : (void *)&((struct sockaddr_in6 *)entry->ai_addr)->sin6_addr;
        inet_ntop(entry->ai_family, addr, text, sizeof text);
        printf("%s -> %s\n", argv[1], text);
    }
    freeaddrinfo(result);
    return 0;
}
