const os = require('os')
const path = require('path')
const fs = require('fs')
const http = require('http')
const net = require('net')
const child_process = require('child_process')
const couchbase = require('couchbase')
const assert = require('assert')

class MockServerSetup {
  mockUrlBase = 'http://packages.couchbase.com/clients/c/mock'
  mockPath = ''
  constructor(mockUrl, mockVersion) {
    if (typeof mockVersion === 'undefined') {
      this.mockVersion = '1.5.25'
      this.mockFile = `CouchbaseMock-${this.mockVersion}.jar`
    }
    if (typeof mockUrl === 'undefined') {
      this.mockUrl = `${this.mockUrlBase}/${this.mockFile}`
    }
  }

  getMockJar(callback) {
    const mockPath = path.join(os.tmpdir(), this.mockFile)
    // Check if the file already exists

    const self = this
    fs.stat(mockPath, (err, stats) => {
      if (!err && stats.isFile() && stats.size > 0) {
        callback(null, mockPath)
        return
      }

      // Remove whatever was there
      fs.unlink(mockPath, () => {
        // we ignore any errors here...
        console.log('downloading ' + self.mockUrl + ' to ' + mockPath)

        const file = fs.createWriteStream(mockPath)
        http.get(self.mockUrl, (res) => {
          if (res.statusCode !== 200) {
            callback(new Error('failed to get mock from server'))
            return
          }

          res
            .on('data', (data) => {
              file.write(data)
            })
            .on('end', () => {
              file.end(() => {
                callback(null, mockPath)
              })
            })
        })
      })
    })
  }

  async getMock() {
    const self = this
    return new Promise((resolve, reject) => {
      self.getMockJar((err, mockPath) => {
        if (err) {
          reject(err)
          return
        }
        self.startMock(mockPath, (err, mock) => {
          if (err) {
            reject(err)
            return
          }
          resolve(mock)
        })
      })
    })
  }

  async sendMockCmd(mock, cmd, payload) {
    return new Promise((resolve, reject) => {
      mock.command(cmd, payload, (err, res) => {
        if (err) {
          reject(err)
          return
        }

        resolve(res)
      })
    })
  }

  startMock(mockPath, callback) {
    const self = this
    const server = net.createServer((socket) => {
      // Close the socket immediately
      server.close()

      let readBuf = null
      let mockPort = -1
      let msgHandlers = []
      socket.on('data', (data) => {
        if (readBuf) {
          readBuf = Buffer.concat([readBuf, data])
        } else {
          readBuf = data
        }

        while (readBuf.length > 0) {
          if (mockPort === -1) {
            var nullIdx = self._bufferIndexOf(readBuf, 0)
            if (nullIdx >= 0) {
              var portStr = readBuf.slice(0, nullIdx)
              readBuf = readBuf.slice(nullIdx + 1)
              mockPort = parseInt(portStr, 10)

              socket.entryPort = mockPort

              callback(null, socket)
              continue
            }
          } else {
            var termIdx = self._bufferIndexOf(readBuf, '\n')
            if (termIdx >= 0) {
              var msgBuf = readBuf.slice(0, termIdx)
              readBuf = readBuf.slice(termIdx + 1)

              var msg = JSON.parse(msgBuf.toString())

              if (msgHandlers.length === 0) {
                console.error('mock response with no handler')
                continue
              }
              var msgHandler = msgHandlers.shift()

              if (msg.status === 'ok') {
                msgHandler(null, msg.payload)
              } else {
                var err = new Error('mock error: ' + msg.error)
                msgHandler(err, null)
              }

              continue
            }
          }
          break
        }
      })
      socket.on('error', (err) => {
        if (socket.userClosed) {
          return
        }

        console.error('mocksock err', err)
      })
      socket.command = (cmdName, payload, callback) => {
        if (callback === undefined) {
          callback = payload
          payload = undefined
        }

        msgHandlers.push(callback)
        var dataOut =
          JSON.stringify({
            command: cmdName,
            payload: payload,
          }) + '\n'
        socket.write(dataOut)
      }
      socket.close = () => {
        socket.userClosed = true
        socket.end()
      }
      console.log('got mock server connection')
    })

    server.on('error', (err) => {
      callback(err)
    })

    server.on('listening', () => {
      var ctlPort = server.address().port

      var javaOpts = [
        '-jar',
        mockPath,
        '--cccp',
        '--harakiri-monitor',
        'localhost:' + ctlPort,
        '--port',
        '0',
        '--replicas',
        '1',
        '--vbuckets',
        '32',
        '--nodes',
        '3',
        '--buckets',
        'default::couchbase',
      ]
      console.log('launching mock:', javaOpts)

      // Start Java Mock Here...
      var mockproc = child_process.spawn('java', javaOpts)
      mockproc.on('error', (err) => {
        server.close()
        callback(err)
        return
      })
      mockproc.stderr.on('data', (data) => {
        console.error('mockproc err: ' + data.toString())
      })
      mockproc.on('close', (code) => {
        if (code !== 0 && code !== 1) {
          console.log('mock closed with non-zero exit code: ' + code)
        }
        server.close()
      })

      mockproc.stdout.on('data', (data) => {
        console.log(data)
      })
    })

    server.listen()
  }

  _bufferIndexOf(buffer, search) {
    if (buffer.indexOf instanceof Function) {
      return buffer.indexOf(search)
    } else {
      if (typeof search === 'string') {
        search = Buffer.from(search)
      } else if (typeof search === 'number' && !isNaN(search)) {
        search = Buffer.from([search])
      }
      for (var i = 0; i < buffer.length; ++i) {
        if (buffer[i] === search[0]) {
          return i
        }
      }
      return -1
    }
  }
}

async function runSmokeTest() {
  let mockSetup
  let mock
  let ports
  let success = false
  for (let i = 0; i < 3; ++i) {
    try {
        mockSetup = new MockServerSetup()
        mock = await mockSetup.getMock()
        ports = await mockSetup.sendMockCmd(mock, 'get_mcports')
        break
    } catch (err) {
        console.error('Mock startup failed:', err)
    }
  }
  
  if(!mock){
    console.log('Unable to create mock server.')
    return false
  }

  try {
    let serverList = []
    for (let portIdx = 0; portIdx < ports.length; ++portIdx) {
      serverList.push('localhost:' + ports[portIdx])
    }

    connstr = 'couchbase://' + serverList.join(',')
    const cluster = await couchbase.connect(connstr, {
      username: 'Administrator',
      password: 'password',
    })

    const bucket = cluster.bucket('default')
    const collection = bucket.defaultCollection()

    const key = 'test-key'
    let doc = {
      a: 'aa',
      b: 1,
      c: ['foo', 'bar'],
      d: { baz: 'quz' },
      what: 'this is a test!',
    }

    let caughtError = false
    try {
      await collection.remove(key)
    } catch (err) {
      caughtError = true
      assert(
        err instanceof couchbase.DocumentNotFoundError,
        'remove() did not raise DocumentNotFoundError'
      )
    }
    assert.equal(caughtError, true, 'remove() did not raise an error')
    caughtError = false

    let res = await collection.insert(key, doc)
    assert(
      res instanceof couchbase.MutationResult,
      'insert() did not return MutationResult'
    )
    assert.ok(res.cas, `insert() returned result w/ cas=${res.cas}`)

    res = await collection.get(key)
    assert(res instanceof couchbase.GetResult)
    assert.ok(res.cas, `get() returned result w/ cas=${res.cas}`)
    assert.deepStrictEqual(res.content, doc, 'get() returned incorrect result')

    try {
      res = await collection.insert(key, doc)
    } catch (err) {
      caughtError = true
      assert(
        err instanceof couchbase.DocumentExistsError,
        'insert() did not raise DocumentExistsError'
      )
    }
    assert.equal(caughtError, true, 'insert() did not raise an error')
    caughtError = false

    doc.what = 'This is an upsert test!'
    res = await collection.upsert(key, doc)
    assert(
      res instanceof couchbase.MutationResult,
      'upsert() did not return MutationResult'
    )
    assert.ok(res.cas, `upsert() returned result w/ cas=${res.cas}`)

    res = await collection.get(key)
    assert(res instanceof couchbase.GetResult)
    assert.ok(res.cas, `get() returned result w/ cas=${res.cas}`)
    assert.deepStrictEqual(res.content, doc, 'get() returned incorrect result')

    doc.what = 'This is an replace test!'
    res = await collection.replace(key, doc)
    assert(
      res instanceof couchbase.MutationResult,
      'replace() did not return MutationResult'
    )
    assert.ok(res.cas, `replace() returned result w/ cas=${res.cas}`)

    res = await collection.get(key)
    assert(res instanceof couchbase.GetResult)
    assert.ok(res.cas, `get() returned result w/ cas=${res.cas}`)
    assert.deepStrictEqual(res.content, doc, 'get() returned incorrect result')

    res = await collection.remove(key, doc)
    assert(
      res instanceof couchbase.MutationResult,
      'remove() did not return MutationResult'
    )
    assert.ok(res.cas, `remove() returned result w/ cas=${res.cas}`)

    try {
      res = await collection.get(key)
    } catch (err) {
      caughtError = true
      assert(
        err instanceof couchbase.DocumentNotFoundError,
        'get() did not raise DocumentNotFoundError'
      )
    }
    assert.equal(caughtError, true, 'get() did not raise an error')
    caughtError = false
    success = true
  } catch (err) {
    console.error('Err:', err)
  } finally {
    if (mock) {
      mock.close()
    }
  }
  return success
}

runSmokeTest()
  .then((success) => {
    console.log(`Smoke test finished. Success=${success}.`)
  })
  .catch((err) => {
    console.error('Err:', err)
  })
