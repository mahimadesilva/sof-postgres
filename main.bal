import ballerina/io;

public function main() {
    var s = transpile("name.given.age", {

                                            resourceAlias: "r",
                                            resourceColumn: "resource"

                                        });
    io:println(s);
}
