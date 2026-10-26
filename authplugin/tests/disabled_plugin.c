#include <Security/AuthorizationPlugin.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(library != NULL);
    OSStatus (*create)(const AuthorizationCallbacks *, AuthorizationPluginRef *,
                      const AuthorizationPluginInterface **) = dlsym(library, "AuthorizationPluginCreate");
    assert(create != NULL);
    AuthorizationPluginRef plugin = (void *)1;
    const AuthorizationPluginInterface *interface = (void *)1;
    assert(create(NULL, &plugin, &interface) == errAuthorizationDenied);
    assert(plugin == NULL && interface == NULL);
    assert(create(NULL, NULL, NULL) == errAuthorizationDenied);
    dlclose(library);
    puts("PASS: native Authorization Plugin entry denies creation and publishes no interface");
    return 0;
}
