/*
 *  Copyright 2016-2024. Couchbase, Inc.
 *  All Rights Reserved.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

const fs = require('fs')
const ini = require('ini')
const path = require('path')
const analytics = require('couchbase-analytics')

const TEST_CONFIG_INI = path.join(path.resolve(__dirname), 'testConfig.ini')

class TestConfig {
    constructor(configData) {
        this._connstr = configData.connstr
        this._database = configData.database
        this._scope = configData.scope
        this._collection = configData.collection
        this._user = configData.user
        this._pass = configData.pass
        this._nonprod = configData.nonprod
        this._disableCertVerification = configData.disableCertVerification
    }

    get connStr() {
        return this._connstr
    }

    get databaseName() {
        return this._database
    }

    get scopeName() {
        return this._scope
    }

    get collectionName() {
        return this._collection
    }

    get fqdn() {
        return `\`${this._database}\`.\`${this._scope}\`.\`${this._collection}\``
    }

    get username() {
        return this._user
    }

    get password() {
        return this._pass
    }

    get nonprod() {
        return this._nonprod
    }

    get disableCertVerification() {
        return this._disableCertVerification
    }
}

function getConfig() {
    let configData = {
        connstr: undefined,
        database: undefined,
        scope: undefined,
        collection: undefined,
        user: undefined,
        pass: undefined,
        nonprod: true,
        disableCertVerification: false,
    }
    const configIni = ini.parse(fs.readFileSync(TEST_CONFIG_INI, 'utf-8'))
    configData.connstr = configIni.connstr
    const fqdnTokens = configIni.fqdn.split('.')
    if (fqdnTokens.length != 3) {
        throw new Error(`Invalid FQDN provided. FQDN=${fqdnTokens.join('.')}`)
    }
    configData.database = fqdnTokens[0]
    configData.scope = fqdnTokens[1]
    configData.collection = fqdnTokens[2]
    configData.user = configIni.username
    configData.pass = configIni.password
    configData.nonprod = configIni.nonprod
    configData.disableCertVerification = configIni.disable_cert_verification

    return new TestConfig(configData)
}

async function runSmokeTest() {
    let success = false

    try {
        const testConfig = getConfig()
        const credential = new analytics.Credential(
            testConfig.username,
            testConfig.password
        )
        let options = {
            timeoutOptions: {
                queryTimeout: 10000,
            },
        }
        if (testConfig.nonprod) {
            options.securityOptions = {
                trustOnlyCertificates: analytics.Certificates.getNonprodCertificates(),
            }
        }

        if (testConfig.disableCertVerification) {
            options.securityOptions = {
                disableServerCertificateVerification: true,
            }
        }

        const cluster = analytics.createInstance(
            testConfig.connStr,
            credential,
            options
        )

        // Execute a streaming query.
        let qs = `FROM RANGE(0, 100) AS i SELECT *`
        let res = await cluster.executeQuery(qs)
        for await (let row of res.rows()) {
            console.log('Found row: ', row)
        }
        console.log('Metadata: ', res.metadata())
        success = true
    } catch (err) {
        console.error('Err:', err)
    }
    return success
}

runSmokeTest()
    .then((success) => {
        console.log(`Smoke test finished. Success=${success}.`)
    })
    .catch((err) => {
        console.log('ERR: ', err)
    })
