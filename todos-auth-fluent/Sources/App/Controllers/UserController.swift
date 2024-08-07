//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2023 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import FluentKit
import Foundation
import Hummingbird
import HummingbirdAuth
import HummingbirdFluent
import NIO
import Tracing

struct UserController<Context: AuthRequestContext & RequestContext> {
    let fluent: Fluent
    let sessionStorage: SessionStorage

    /// Add routes for user controller
    func addRoutes(to group: RouterGroup<Context>) {
        group.post(use: self.create)
        group.group("login").add(middleware: BasicAuthenticator(fluent: self.fluent))
            .post(use: self.login)
        group.add(middleware: SessionAuthenticator(fluent: self.fluent, sessionStorage: self.sessionStorage))
            .get(use: self.current)
            .post("logout", use: self.logout)
    }

    /// Create new user
    /// Used in tests, as user creation is done by ``WebController.signupDetails``
    @Sendable func create(_ request: Request, context: Context) async throws -> EditedResponse<UserResponse> {
        try await withSpan("create user") { span in
            let createUser = try await request.decode(as: CreateUserRequest.self, context: context)
            
            do {
                let user = try await User.create(
                    name: createUser.name,
                    email: createUser.email,
                    password: createUser.password,
                    db: self.fluent.db()
                )
                
                span.attributes["name"] = user.name
                span.attributes["email"] = user.email
                return .init(status: .created, response: UserResponse(from: user))
            } catch {
                span.recordError(error)
                span.setStatus(.init(code: .error))
                throw error
            }
        }
    }

    /// Login user and create session
    /// Used in tests, as user creation is done by ``WebController.loginDetails``
    @Sendable func login(_ request: Request, context: Context) async throws -> Response {
        // get authenticated user and return
        let user = try context.auth.require(User.self)
        // create session lasting 1 hour
        let cookie = try await self.sessionStorage.save(session: user.requireID(), expiresIn: .seconds(3600))
        var response = Response(status: .ok)
        response.setCookie(cookie)
        return response
    }

    /// Login user and create session
    @Sendable func logout(_ request: Request, context: Context) async throws -> HTTPResponse.Status {
        // get authenticated user and return
        let user = try context.auth.require(User.self)
        // create session finishing now
        try await self.sessionStorage.update(session: user.requireID(), expiresIn: .seconds(0), request: request)
        return .ok
    }

    /// Get current logged in user
    @Sendable func current(_ request: Request, context: Context) throws -> UserResponse {
        // get authenticated user and return
        let user = try context.auth.require(User.self)
        return UserResponse(from: user)
    }
}
