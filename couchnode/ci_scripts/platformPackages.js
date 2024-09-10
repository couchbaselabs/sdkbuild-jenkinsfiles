const fs = require('fs')
const path = require('path')

let dirPath = ''
let createPlatPackageJson = false
let buildPlatPackages = false
const args = process.argv.slice(2)
if (args.length > 0) {
  // --create-platform-package-json
  if (args.includes('--create-platform-package-json')) {
    createPlatPackageJson = true
  }

  // --build-platform-packages
  if (args.includes('--build-platform-packages')) {
    buildPlatPackages = true
  }

  if (createPlatPackageJson && buildPlatPackages) {
    console.log(
      'Cannot create platform package.json and build platform packages.'
    )
    process.exit(1)
  }

  if (!(createPlatPackageJson || buildPlatPackages)) {
    console.log(
      'Please specify an option [--create-platform-package-json | --build-platform-packages].'
    )
    process.exit(1)
  }

  if (buildPlatPackages) {
    // --[dir|d|directory]=<> OR --[dir|d|directory] <>
    const dirIdx = args.findIndex((a) => {
      return a === '--dir' || a === '--d' || a === '--directory'
    })
    if (dirIdx >= 0) {
      if (args[dirIdx].includes('=')) {
        dirPath = args[dirIdx].split('=')[1]
      } else {
        dirPath = args[dirIdx + 1]
      }
    }
  }
}

if (createPlatPackageJson) {
  localDir = path.resolve('.')
  const pkgJsonKeys = ['version', 'bugs', 'homepage', 'license', 'repository']
  let pkgJson = JSON.parse(fs.readFileSync(path.join(localDir, 'package.json')))
  pkgJson = Object.fromEntries(
    Object.entries(pkgJson).filter(([k]) => pkgJsonKeys.includes(k))
  )
  fs.writeFileSync(
    path.join(localDir, 'platPkg.json'),
    JSON.stringify(pkgJson, null, 2)
  )
}

if (buildPlatPackages) {
  if (!fs.existsSync(dirPath)) {
    console.log(`Path (${dirPath}) provided does not exist.`)
    process.exit(1)
  }

  const optionalDependencies = []
  let dirContents = fs.readdirSync(dirPath)
  for (let i = 0; i < dirContents.length; i++) {
    if (
      !(
        fs.statSync(path.join(dirPath, dirContents[i])).isFile() &&
        dirContents[i].endsWith('.node')
      )
    ) {
      continue
    }
    const prebuildTokens = dirContents[i].split('-')
    if (![8, 9].includes(prebuildTokens.length)) {
      console.log(
        `Unexpected number of tokens in prebuild name: ${dirContents[i]}.  Got ${prebuildTokens.length} tokens, expected 7 or 8.`
      )
    }
    const platform = prebuildTokens[prebuildTokens.length - 3]
    const osPlatform = platform.includes('musl') ? 'linux' : platform
    const arch = prebuildTokens[prebuildTokens.length - 2]
    const runtime = prebuildTokens[prebuildTokens.length - 5]
    const platformPkgDir = `couchbase-${platform}-${arch}-${runtime}`
    const platformPkgName = `@couchbase/${platformPkgDir}`
    const descList = [
      'Capella Columnar Node.js SDK platform specific binary for',
      `${runtime} runtime on ${platform} OS`,
      `with ${arch} architecture and boringssl.`,
    ]
    const description = descList.join(' ')

    let pkgJson = JSON.parse(fs.readFileSync('platPkg.json'))
    pkgJson.engines = { node: '>=16' }
    pkgJson.name = platformPkgName
    pkgJson.os = [osPlatform]
    pkgJson.cpu = [arch]
    pkgJson.descripton = description
    fs.mkdirSync(path.join(dirPath, platformPkgDir))
    fs.writeFileSync(
      path.join(dirPath, platformPkgDir, 'package.json'),
      JSON.stringify(pkgJson, null, 2)
    )
    fs.renameSync(
      path.join(dirPath, dirContents[i]),
      path.join(dirPath, platformPkgDir, dirContents[i])
    )
    fs.writeFileSync(path.join(dirPath, platformPkgDir, 'index.js'), '')
    fs.writeFileSync(
      path.join(dirPath, platformPkgDir, 'README.md'),
      description
    )
    optionalDependencies.push(platformPkgName)
  }
  console.log('Optional dependencies = ', optionalDependencies)
}
