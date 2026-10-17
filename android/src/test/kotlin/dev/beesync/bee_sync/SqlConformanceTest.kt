package dev.beesync.bee_sync

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class SqlConformanceTest {
    @Test
    fun schemaMatchesSpec() {
        assertEquals(
            parseSpec(File(specDir, "schema.sql")),
            Sql.schemaStatements.mapValues { normalizeSql(it.value) },
        )
    }

    @Test
    fun claimProtocolMatchesSpec() {
        assertEquals(
            parseSpec(File(specDir, "claim_protocol.sql")),
            Sql.protocolStatements.mapValues { normalizeSql(it.value) },
        )
    }
}
