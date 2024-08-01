import FluentSQLiteDriver
import FluentPostgresDriver
import Foundation
import Hummingbird
import HummingbirdAuth
import HummingbirdFluent
import Logging
import Metrics
import OTel
import OTLPGRPC
import Tracing
import Mustache

public protocol AppArguments {
    var inMemoryDatabase: Bool { get }
    var migrate: Bool { get }
    var hostname: String { get }
    var port: Int { get }
}

func buildApplication(_ arguments: some AppArguments) async throws -> some ApplicationProtocol {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label, metadataProvider: .otel)
        handler.logLevel = .trace
        return handler
    }
    let logger = Logger(label: "todos-auth-fluent")
    
    let environment = OTelEnvironment.detected()
    let resourceDetection = OTelResourceDetection(detectors: [
        OTelProcessResourceDetector(),
        OTelEnvironmentResourceDetector(environment: environment),
        .manual(OTelResource(attributes: ["service.name": "todos-auth-fluent-server"])),
    ])
    let resource = await resourceDetection.resource(environment: environment, logLevel: .trace)
    // Bootstrap the metrics backend to export metrics periodically in OTLP/gRPC.
    let registry = OTelMetricRegistry()
    let metricsExporter = try OTLPGRPCMetricExporter(configuration: .init(environment: environment))
    let metrics = OTelPeriodicExportingMetricsReader(
        resource: resource,
        producer: registry,
        exporter: metricsExporter,
        configuration: .init(
            environment: environment,
            exportInterval: .seconds(5) // NOTE: This is overridden for the example; the default is 60 seconds.
        )
    )
    MetricsSystem.bootstrap(OTLPMetricsFactory(registry: registry))
    
    // Bootstrap the tracing backend to export traces periodically in OTLP/gRPC.
    let exporter = try OTLPGRPCSpanExporter(configuration: .init(environment: environment))
    let processor = OTelBatchSpanProcessor(exporter: exporter, configuration: .init(environment: environment))
    let tracer = OTelTracer(
        idGenerator: OTelRandomIDGenerator(),
        sampler: OTelConstantSampler(isOn: true),
        propagator: OTelW3CPropagator(),
        processor: processor,
        environment: environment,
        resource: resource
    )
    InstrumentationSystem.bootstrap(tracer)
    
    let fluent = Fluent(logger: logger)
    // add sqlite database
    if arguments.inMemoryDatabase {
        fluent.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        fluent.databases.use(
            .postgres(
                configuration: .init(
                    hostname: "nas",
                    username: "shared",
                    password: "selfhost-app-data",
                    database: "todo_app_db",
                    tls: .disable
                )
            ),
            as: .psql
        )
    }
    // add migrations
    await fluent.migrations.add(CreateUser())
    await fluent.migrations.add(CreateTodo())

    let fluentPersist = await FluentPersistDriver(fluent: fluent)
    // migrate
    if arguments.migrate || arguments.inMemoryDatabase {
        try await fluent.migrate()
    }
    let sessionStorage = SessionStorage(fluentPersist)
    // router
    let router = Router(context: TodosAuthRequestContext.self)
    router.middlewares.add(TracingMiddleware())
    router.middlewares.add(MetricsMiddleware())
    router.middlewares.add(LogRequestsMiddleware(.info))

    // add logging middleware
    router.add(middleware: LogRequestsMiddleware(.info))
    // add file middleware to server css and js files
    router.add(middleware: FileMiddleware(logger: logger))
    router.add(middleware: CORSMiddleware(
        allowOrigin: .originBased,
        allowHeaders: [.contentType],
        allowMethods: [.get, .options, .post, .delete, .patch]
    ))
    // add health check route
    router.get("/health") { _, _ in
        return HTTPResponse.Status.ok
    }

    // load mustache template library
    let library = try await MustacheLibrary(directory: "templates")
    assert(library.getTemplate(named: "head") != nil, "Set your working directory to the root folder of this example to get it to work")

    // Add routes serving HTML files
    WebController(mustacheLibrary: library, fluent: fluent, sessionStorage: sessionStorage).addRoutes(to: router)
    // Add api routes managing todos
    TodoController(fluent: fluent, sessionStorage: sessionStorage).addRoutes(to: router.group("api/todos"))
    // Add api routes managing users
    UserController(fluent: fluent, sessionStorage: sessionStorage).addRoutes(to: router.group("api/users"))

    var app = Application(
        router: router,
        configuration: .init(address: .hostname(arguments.hostname, port: arguments.port))
    )
    app.addServices(metrics, tracer, fluent, fluentPersist)
    return app
}
